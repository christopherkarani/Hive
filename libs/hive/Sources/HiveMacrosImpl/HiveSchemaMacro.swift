import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct HiveSchemaMacro: MemberMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let channels = collectChannels(in: declaration, context: context)
        guard !channels.isEmpty else { return [] }

        var decls: [DeclSyntax] = []
        for channel in channels {
            decls.append(DeclSyntax(stringLiteral: channel.keyDecl))
        }

        if !declarationHasChannelSpecs(declaration) {
            let specsDecl = channelSpecsDecl(channels)
            decls.append(DeclSyntax(stringLiteral: specsDecl))
        }

        return decls
    }
}

private struct ChannelDescriptor {
    let keyName: String
    let channelID: String
    let valueType: String
    let initialExpr: String
    let scopeExpr: String
    let reducerExpr: String
    let updatePolicyExpr: String
    let persistenceExpr: String
    let codecExpr: String

    var keyDecl: String {
        "static let \(keyName) = HiveChannelKey<Self, \(valueType)>(HiveChannelID(\"\(channelID)\"))"
    }
}

private enum HiveMacroDiagnostic: String, DiagnosticMessage {
    case taskLocalUntracked

    var message: String {
        switch self {
        case .taskLocalUntracked:
            "Task-local channels must be checkpointed."
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "HiveMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}

private func collectChannels(
    in declaration: some DeclGroupSyntax,
    context: some MacroExpansionContext
) -> [ChannelDescriptor] {
    var channels: [ChannelDescriptor] = []

    for member in declaration.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
              let type = binding.typeAnnotation?.type
        else { continue }

        guard let attribute = channelAttribute(from: varDecl) else { continue }

        let propertyName = pattern.identifier.text
        let (keyName, channelID) = channelKeyNames(from: propertyName)
        let valueType = type.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialExpr = binding.initializer?.value
            .description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(valueType)()"

        let args = parseArguments(attribute)
        let reducerRaw = args["reducer"] ?? "lastWriteWins()"
        let reducerExpr = normalizeReducer(reducerRaw)

        let updatePolicyRaw = args["updatePolicy"] ?? "single"
        let persistenceRaw = args["persistence"] ?? "untracked"

        let isTaskLocal = attribute.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines) == "TaskLocalChannel"
        let scopeRaw = isTaskLocal ? "taskLocal" : (args["scope"] ?? "global")

        let scopeExpr = normalizeScope(scopeRaw)
        let updatePolicyExpr = normalizeUpdatePolicy(updatePolicyRaw)
        let persistenceExpr = normalizePersistence(persistenceRaw)

        if scopeExpr == ".taskLocal", persistenceExpr == ".untracked" {
            context.diagnose(Diagnostic(node: Syntax(attribute), message: HiveMacroDiagnostic.taskLocalUntracked))
        }

        let requiresCodec = (scopeExpr == ".taskLocal") || (persistenceExpr == ".checkpointed")
        let codecRaw = args["codec"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codecExpr: String
        if let codecRaw, codecRaw.isEmpty == false {
            codecExpr = normalizeCodecExpr(codecRaw)
        } else if requiresCodec {
            codecExpr = "HiveAnyCodec(HiveJSONCodec<\(valueType)>())"
        } else {
            codecExpr = "nil"
        }

        channels.append(
            ChannelDescriptor(
                keyName: keyName,
                channelID: channelID,
                valueType: valueType,
                initialExpr: initialExpr,
                scopeExpr: scopeExpr,
                reducerExpr: reducerExpr,
                updatePolicyExpr: updatePolicyExpr,
                persistenceExpr: persistenceExpr,
                codecExpr: codecExpr
            )
        )
    }

    return channels
}

private func channelSpecsDecl(_ channels: [ChannelDescriptor]) -> String {
    var lines: [String] = []
    lines.append("static var channelSpecs: [AnyHiveChannelSpec<Self>] {")
    lines.append("    [")
    for (index, channel) in channels.enumerated() {
        lines.append("        AnyHiveChannelSpec(")
        lines.append("            HiveChannelSpec(")
        lines.append("                key: Self.\(channel.keyName),")
        lines.append("                scope: \(channel.scopeExpr),")
        lines.append("                reducer: \(channel.reducerExpr),")
        lines.append("                updatePolicy: \(channel.updatePolicyExpr),")
        lines.append("                initial: { \(channel.initialExpr) },")
        lines.append("                codec: \(channel.codecExpr),")
        lines.append("                persistence: \(channel.persistenceExpr)")
        lines.append("            )")
        if index == channels.count - 1 {
            lines.append("        )")
        } else {
            lines.append("        ),")
        }
    }
    lines.append("    ]")
    lines.append("}")

    return lines.joined(separator: "\n")
}

private func declarationHasChannelSpecs(_ declaration: some DeclGroupSyntax) -> Bool {
    for member in declaration.memberBlock.members {
        guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
        for binding in varDecl.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            if pattern.identifier.text == "channelSpecs" {
                return true
            }
        }
    }
    return false
}

private func channelAttribute(from decl: VariableDeclSyntax) -> AttributeSyntax? {
    for attribute in decl.attributes {
        guard let attr = attribute.as(AttributeSyntax.self) else { continue }
        let name = attr.attributeName.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "Channel" || name == "TaskLocalChannel" {
            return attr
        }
    }
    return nil
}

private func channelKeyNames(from propertyName: String) -> (String, String) {
    if propertyName.hasPrefix("_") {
        let trimmed = String(propertyName.dropFirst())
        return (trimmed, trimmed)
    }
    return ("\(propertyName)Key", propertyName)
}

private func parseArguments(_ attribute: AttributeSyntax) -> [String: String] {
    guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else { return [:] }
    var values: [String: String] = [:]
    for argument in arguments {
        guard let label = argument.label?.text else { continue }
        if let literal = stringLiteralValue(argument.expression) {
            values[label] = literal
        }
    }
    return values
}

private func stringLiteralValue(_ expr: ExprSyntax) -> String? {
    guard let literal = expr.as(StringLiteralExprSyntax.self) else { return nil }
    let segments = literal.segments.compactMap { segment -> String? in
        guard let segment = segment.as(StringSegmentSyntax.self) else { return nil }
        return segment.content.text
    }
    return segments.joined()
}

private func normalizeReducer(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(".") { return trimmed }
    if trimmed.contains(".") { return trimmed }
    return ".\(trimmed)"
}

private func normalizeScope(_ raw: String) -> String {
    switch raw.lowercased() {
    case "global":
        return ".global"
    case "tasklocal":
        return ".taskLocal"
    default:
        return ".global"
    }
}

private func normalizeUpdatePolicy(_ raw: String) -> String {
    switch raw.lowercased() {
    case "single":
        return ".single"
    case "multi":
        return ".multi"
    default:
        return ".single"
    }
}

private func normalizePersistence(_ raw: String) -> String {
    switch raw.lowercased() {
    case "checkpointed":
        return ".checkpointed"
    case "untracked":
        return ".untracked"
    default:
        return ".untracked"
    }
}

private func normalizeCodecExpr(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "nil" { return "nil" }
    if trimmed.hasPrefix("HiveAnyCodec(") { return trimmed }
    return "HiveAnyCodec(\(trimmed))"
}
