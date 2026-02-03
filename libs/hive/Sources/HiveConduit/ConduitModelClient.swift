import Foundation
import HiveCore
import Conduit

/// Conduit-backed implementation of `HiveModelClient`.
public struct ConduitModelClient<Provider: TextGenerator>: HiveModelClient, Sendable {
    private let provider: Provider
    private let modelIDForName: @Sendable (String) throws -> Provider.ModelID
    private let messageID: @Sendable () -> String
    private let config: GenerateConfig

    /// Creates a Conduit-backed model client.
    ///
    /// - Parameters:
    ///   - provider: The Conduit text generator.
    ///   - modelIDForName: Maps Hive model names to provider model identifiers.
    ///   - messageID: Generator for Hive message IDs in responses.
    ///   - config: Base Conduit generation configuration.
    public init(
        provider: Provider,
        config: GenerateConfig = .default,
        modelIDForName: @escaping @Sendable (String) throws -> Provider.ModelID,
        messageID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.provider = provider
        self.modelIDForName = modelIDForName
        self.messageID = messageID
        self.config = config
    }

    public func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        try await streamFinal(request)
    }

    public func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let modelID = try modelIDForName(request.model)
                    let messages = try Self.makeMessages(from: request.messages)
                    let config = try Self.makeConfig(from: request, base: config)
                    let stream = provider.streamWithMetadata(messages: messages, model: modelID, config: config)

                    var accumulatedText = ""
                    var pendingFinal: HiveChatResponse?

                    for try await chunk in stream {
                        if pendingFinal != nil {
                            throw HiveRuntimeError.modelStreamInvalid("Received chunk after final completion.")
                        }

                        if !chunk.text.isEmpty {
                            accumulatedText.append(chunk.text)
                            continuation.yield(.token(chunk.text))
                        }

                        if chunk.isComplete {
                            if pendingFinal != nil {
                                throw HiveRuntimeError.modelStreamInvalid("Received multiple final completion chunks.")
                            }
                            let toolCalls = chunk.completedToolCalls ?? []
                            let response = Self.makeResponse(
                                messageID: messageID,
                                text: accumulatedText,
                                toolCalls: toolCalls
                            )
                            pendingFinal = response
                        }
                    }

                    guard let final = pendingFinal else {
                        throw HiveRuntimeError.modelStreamInvalid("Missing final completion chunk.")
                    }

                    continuation.yield(.final(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Conversions

    private static func makeMessages(from messages: [HiveChatMessage]) throws -> [Message] {
        let toolNameByID = toolNameByCallID(from: messages)
        return try messages.compactMap { message in
            try makeMessage(from: message, toolNameByID: toolNameByID)
        }
    }

    private static func makeMessage(
        from message: HiveChatMessage,
        toolNameByID: [String: String]
    ) throws -> Message? {
        guard message.op == nil else {
            return nil
        }

        switch message.role {
        case .system:
            return Message(role: .system, content: .text(message.content))
        case .user:
            return Message(role: .user, content: .text(message.content))
        case .assistant:
            let toolCalls = try message.toolCalls.map(makeToolCall(from:))
            if !toolCalls.isEmpty {
                return Message.assistant(message.content, toolCalls: toolCalls)
            }
            return Message(role: .assistant, content: .text(message.content))
        case .tool:
            guard let toolCallID = message.toolCallID else {
                throw ConduitModelClientError.missingToolCallID("Tool message is missing toolCallID.")
            }
            let toolName = message.name ?? toolNameByID[toolCallID]
            guard let toolName else {
                throw ConduitModelClientError.unknownToolName(
                    "Tool message is missing name and cannot resolve toolCallID: \(toolCallID)."
                )
            }
            let output = Transcript.ToolOutput(
                id: toolCallID,
                toolName: toolName,
                segments: [.text(.init(content: message.content))]
            )
            return Message.toolOutput(output)
        }
    }

    private static func toolNameByCallID(from messages: [HiveChatMessage]) -> [String: String] {
        var map: [String: String] = [:]
        for message in messages {
            for call in message.toolCalls {
                map[call.id] = call.name
            }
        }
        return map
    }

    private static func makeToolCall(from call: HiveToolCall) throws -> Transcript.ToolCall {
        do {
            return try Transcript.ToolCall(
                id: call.id,
                toolName: call.name,
                argumentsJSON: call.argumentsJSON
            )
        } catch {
            throw ConduitModelClientError.invalidToolArgumentsJSON(
                "Failed to parse tool call arguments for \(call.name): \(error)"
            )
        }
    }

    private static func makeConfig(
        from request: HiveChatRequest,
        base: GenerateConfig
    ) throws -> GenerateConfig {
        guard !request.tools.isEmpty else {
            return base
        }
        let toolDefinitions = try request.tools.map(makeToolDefinition(from:))
        return base.tools(toolDefinitions)
    }

    private static func makeToolDefinition(from tool: HiveToolDefinition) throws -> Transcript.ToolDefinition {
        let trimmed = tool.parametersJSONSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConduitModelClientError.invalidToolSchema("Empty schema for tool \(tool.name)")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ConduitModelClientError.invalidToolSchema("Invalid UTF-8 schema for tool \(tool.name)")
        }
        do {
            let schema = try JSONDecoder().decode(GenerationSchema.self, from: data)
            return Transcript.ToolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: schema
            )
        } catch {
            throw ConduitModelClientError.invalidToolSchema(
                "Failed to decode schema for tool \(tool.name): \(error)"
            )
        }
    }

    private static func makeResponse(
        messageID: @Sendable () -> String,
        text: String,
        toolCalls: [Transcript.ToolCall]
    ) -> HiveChatResponse {
        let hiveToolCalls = toolCalls.map { call in
            HiveToolCall(
                id: call.id,
                name: call.toolName,
                argumentsJSON: call.arguments.jsonString
            )
        }
        let message = HiveChatMessage(
            id: messageID(),
            role: .assistant,
            content: text,
            toolCalls: hiveToolCalls
        )
        return HiveChatResponse(message: message)
    }
}

public enum ConduitModelClientError: Error, Sendable {
    case invalidToolSchema(String)
    case invalidToolArgumentsJSON(String)
    case missingToolCallID(String)
    case unknownToolName(String)
}
