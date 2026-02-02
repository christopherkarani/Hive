import Foundation
import HiveCore
import SwiftAgents

/// Errors surfaced by the SwiftAgents tool registry adapter.
public enum SwiftAgentsToolRegistryError: Error, Sendable {
    case invalidArgumentsJSON(String)
    case argumentsNotObject
    case resultEncodingFailed(String)
    case schemaEncodingFailed(String)
}

/// Bridges SwiftAgents `AnyJSONTool` values to `HiveToolRegistry`.
public struct SwiftAgentsToolRegistry: HiveToolRegistry, Sendable {
    private let registry: ToolRegistry
    private let toolDefinitions: [HiveToolDefinition]

    /// Creates a registry from a static set of SwiftAgents tools.
    public init(tools: [any AnyJSONTool]) throws {
        let uniqueTools = Self.deduplicateTools(tools)
        self.registry = ToolRegistry(tools: uniqueTools)
        self.toolDefinitions = try Self.makeToolDefinitions(from: uniqueTools)
    }

    /// Creates a registry from an existing SwiftAgents `ToolRegistry`.
    ///
    /// - Note: Tool definitions are snapshotted at initialization time.
    public static func fromRegistry(_ registry: ToolRegistry) async throws -> SwiftAgentsToolRegistry {
        let tools = await registry.allTools
        let definitions = try Self.makeToolDefinitions(from: tools)
        return SwiftAgentsToolRegistry(registry: registry, toolDefinitions: definitions)
    }

    /// Returns Hive tool definitions for all registered tools.
    public func listTools() -> [HiveToolDefinition] {
        toolDefinitions
    }

    /// Invokes a SwiftAgents tool and returns a JSON-stringified result.
    public func invoke(_ call: HiveToolCall) async throws -> HiveToolResult {
        let arguments = try Self.decodeArgumentsJSON(call.argumentsJSON)
        let result = try await registry.execute(toolNamed: call.name, arguments: arguments)
        let content = try Self.encodeJSON(value: result)
        return HiveToolResult(toolCallID: call.id, content: content)
    }

    // MARK: - Private

    private init(registry: ToolRegistry, toolDefinitions: [HiveToolDefinition]) {
        self.registry = registry
        self.toolDefinitions = toolDefinitions
    }

    private static func deduplicateTools(_ tools: [any AnyJSONTool]) -> [any AnyJSONTool] {
        var byName: [String: any AnyJSONTool] = [:]
        for tool in tools {
            byName[tool.name] = tool
        }
        return Array(byName.values)
    }

    private static func makeToolDefinitions(from tools: [any AnyJSONTool]) throws -> [HiveToolDefinition] {
        let definitions = try tools.map { tool in
            let schemaObject = jsonSchemaObject(for: tool.parameters)
            let schemaJSON = try encodeJSONObject(schemaObject, error: .schemaEncodingFailed("Tool: \(tool.name)"))
            return HiveToolDefinition(
                name: tool.name,
                description: tool.description,
                parametersJSONSchema: schemaJSON
            )
        }
        return definitions.sorted(by: toolDefinitionSort)
    }

    private static func toolDefinitionSort(_ lhs: HiveToolDefinition, _ rhs: HiveToolDefinition) -> Bool {
        lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }

    private static func jsonSchemaObject(for parameters: [ToolParameter]) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []

        for param in parameters {
            properties[param.name] = schemaObject(for: param)
            if param.isRequired {
                required.append(param.name)
            }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]

        if !required.isEmpty {
            schema["required"] = required
        }

        return schema
    }

    private static func schemaObject(for parameter: ToolParameter) -> [String: Any] {
        var schema = schemaObject(for: parameter.type)
        schema["description"] = parameter.description
        if let defaultValue = parameter.defaultValue {
            schema["default"] = jsonObject(from: defaultValue)
        }
        return schema
    }

    private static func schemaObject(for type: ToolParameter.ParameterType) -> [String: Any] {
        switch type {
        case .string:
            return ["type": "string"]
        case .int:
            return ["type": "integer"]
        case .double:
            return ["type": "number"]
        case .bool:
            return ["type": "boolean"]
        case let .array(elementType):
            return ["type": "array", "items": schemaObject(for: elementType)]
        case let .object(properties):
            var nested: [String: Any] = [:]
            var required: [String] = []
            for property in properties {
                nested[property.name] = schemaObject(for: property)
                if property.isRequired {
                    required.append(property.name)
                }
            }
            var schema: [String: Any] = [
                "type": "object",
                "properties": nested
            ]
            if !required.isEmpty {
                schema["required"] = required
            }
            return schema
        case let .oneOf(options):
            return [
                "type": "string",
                "enum": options
            ]
        case .any:
            return [:]
        }
    }

    private static func decodeArgumentsJSON(_ json: String) throws -> [String: SendableValue] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw SwiftAgentsToolRegistryError.invalidArgumentsJSON(
                "Empty arguments JSON. Use {} when no arguments are required."
            )
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw SwiftAgentsToolRegistryError.invalidArgumentsJSON("Invalid UTF-8 arguments.")
        }

        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let value = try sendableValue(from: object)

        guard case let .dictionary(arguments) = value else {
            throw SwiftAgentsToolRegistryError.argumentsNotObject
        }

        return arguments
    }

    private static func encodeJSON(value: SendableValue) throws -> String {
        let object = jsonObject(from: value)
        return try encodeJSONObject(object, error: .resultEncodingFailed("Failed to encode tool result."))
    }

    private static func encodeJSONObject(_ object: Any, error: SwiftAgentsToolRegistryError) throws -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
            guard let string = String(data: data, encoding: .utf8) else {
                throw error
            }
            return string
        } catch {
            throw error
        }
    }

    private static func sendableValue(from object: Any) throws -> SendableValue {
        switch object {
        case is NSNull:
            return .null
        case let int as Int:
            return .int(int)
        case let double as Double:
            if double.truncatingRemainder(dividingBy: 1) == 0,
               double >= Double(Int.min),
               double <= Double(Int.max) {
                return .int(Int(double))
            }
            return .double(double)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let value = number.doubleValue
            if value.truncatingRemainder(dividingBy: 1) == 0,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return .int(Int(value))
            }
            return .double(value)
        case let bool as Bool:
            return .bool(bool)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return try .array(array.map { try sendableValue(from: $0) })
        case let dict as [String: Any]:
            var result: [String: SendableValue] = [:]
            for (key, value) in dict {
                result[key] = try sendableValue(from: value)
            }
            return .dictionary(result)
        default:
            throw SwiftAgentsToolRegistryError.invalidArgumentsJSON(
                "Unsupported JSON value: \(type(of: object))"
            )
        }
    }

    private static func jsonObject(from value: SendableValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case let .bool(v):
            return v
        case let .int(v):
            return v
        case let .double(v):
            return v
        case let .string(v):
            return v
        case let .array(v):
            return v.map { jsonObject(from: $0) }
        case let .dictionary(v):
            var result: [String: Any] = [:]
            for (key, value) in v {
                result[key] = jsonObject(from: value)
            }
            return result
        }
    }
}
