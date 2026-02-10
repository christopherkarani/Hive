import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct WorkflowBlueprintMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf _: some DeclGroupSyntax,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else {
            return []
        }
        let ext = try ExtensionDeclSyntax("extension \(type): WorkflowBlueprint {}")
        return [ext]
    }
}
