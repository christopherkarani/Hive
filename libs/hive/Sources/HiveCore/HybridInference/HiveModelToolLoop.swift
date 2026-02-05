/// Configuration for the reusable model/tool loop engine.
public struct HiveModelToolLoopConfiguration: Sendable {
    /// How model calls are executed for each loop iteration.
    public enum ModelCallMode: Sendable {
        case complete
        case stream
    }

    /// Deterministic ordering strategy for tool calls.
    public enum ToolCallOrder: Sendable {
        case asEmitted
        case byNameThenID
    }

    public let modelCallMode: ModelCallMode
    public let maxModelInvocations: Int
    public let toolCallOrder: ToolCallOrder

    public init(
        modelCallMode: ModelCallMode,
        maxModelInvocations: Int,
        toolCallOrder: ToolCallOrder
    ) {
        self.modelCallMode = modelCallMode
        self.maxModelInvocations = maxModelInvocations
        self.toolCallOrder = toolCallOrder
    }
}

/// Final loop result plus deterministic messages appended by the loop.
public struct HiveModelToolLoopResult: Sendable {
    public let finalResponse: HiveChatResponse
    public let appendedMessages: [HiveChatMessage]

    public init(finalResponse: HiveChatResponse, appendedMessages: [HiveChatMessage]) {
        self.finalResponse = finalResponse
        self.appendedMessages = appendedMessages
    }
}

/// Reusable bounded loop for model/tool execution.
public enum HiveModelToolLoop {
    public typealias StreamEventEmitter =
        @Sendable (_ kind: HiveStreamEventKind, _ metadata: [String: String]) -> Void

    public static func run(
        request: HiveChatRequest,
        modelClient: AnyHiveModelClient,
        toolRegistry: AnyHiveToolRegistry?,
        configuration: HiveModelToolLoopConfiguration,
        emitStream: @escaping StreamEventEmitter = { _, _ in }
    ) async throws -> HiveModelToolLoopResult {
        guard configuration.maxModelInvocations > 0 else {
            throw HiveRuntimeError.invalidRunOptions("maxModelInvocations must be >= 1")
        }

        var conversation = request.messages
        var appendedMessages: [HiveChatMessage] = []
        var modelInvocations = 0

        while true {
            guard modelInvocations < configuration.maxModelInvocations else {
                throw HiveRuntimeError.modelToolLoopMaxModelInvocationsExceeded(
                    maxModelInvocations: configuration.maxModelInvocations
                )
            }
            modelInvocations += 1

            let modelRequest = HiveChatRequest(
                model: request.model,
                messages: conversation,
                tools: request.tools
            )
            let response = try await invokeModel(
                request: modelRequest,
                modelClient: modelClient,
                mode: configuration.modelCallMode,
                emitStream: emitStream
            )

            let assistantMessage = response.message
            conversation.append(assistantMessage)
            appendedMessages.append(assistantMessage)

            guard !assistantMessage.toolCalls.isEmpty else {
                return HiveModelToolLoopResult(
                    finalResponse: response,
                    appendedMessages: appendedMessages
                )
            }

            guard let toolRegistry else {
                throw HiveRuntimeError.toolRegistryMissing
            }

            for toolCall in orderedToolCalls(
                assistantMessage.toolCalls,
                order: configuration.toolCallOrder
            ) {
                emitStream(.toolInvocationStarted(name: toolCall.name), [:])
                do {
                    let result = try await toolRegistry.invoke(toolCall)
                    emitStream(.toolInvocationFinished(name: toolCall.name, success: true), [:])

                    let toolMessage = HiveChatMessage(
                        id: "tool:\(toolCall.id)",
                        role: .tool,
                        content: result.content,
                        name: toolCall.name,
                        toolCallID: toolCall.id
                    )
                    conversation.append(toolMessage)
                    appendedMessages.append(toolMessage)
                } catch {
                    emitStream(.toolInvocationFinished(name: toolCall.name, success: false), [:])
                    throw error
                }
            }
        }
    }

    private static func invokeModel(
        request: HiveChatRequest,
        modelClient: AnyHiveModelClient,
        mode: HiveModelToolLoopConfiguration.ModelCallMode,
        emitStream: StreamEventEmitter
    ) async throws -> HiveChatResponse {
        emitStream(.modelInvocationStarted(model: request.model), [:])
        defer {
            emitStream(.modelInvocationFinished, [:])
        }

        switch mode {
        case .complete:
            return try await modelClient.complete(request)
        case .stream:
            return try await streamFinal(request: request, modelClient: modelClient, emitStream: emitStream)
        }
    }

    private static func streamFinal(
        request: HiveChatRequest,
        modelClient: AnyHiveModelClient,
        emitStream: StreamEventEmitter
    ) async throws -> HiveChatResponse {
        var sawFinal = false
        var finalResponse: HiveChatResponse?

        for try await chunk in modelClient.stream(request) {
            switch chunk {
            case .token(let text):
                if sawFinal {
                    throw HiveRuntimeError.modelStreamInvalid("Received token after final chunk.")
                }
                emitStream(.modelToken(text: text), [:])
            case .final(let response):
                if sawFinal {
                    throw HiveRuntimeError.modelStreamInvalid("Received multiple final chunks.")
                }
                sawFinal = true
                finalResponse = response
            }
        }

        guard let finalResponse else {
            throw HiveRuntimeError.modelStreamInvalid("Missing final chunk.")
        }
        return finalResponse
    }

    private static func orderedToolCalls(
        _ toolCalls: [HiveToolCall],
        order: HiveModelToolLoopConfiguration.ToolCallOrder
    ) -> [HiveToolCall] {
        switch order {
        case .asEmitted:
            toolCalls
        case .byNameThenID:
            toolCalls.sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.argumentsJSON < rhs.argumentsJSON
            }
        }
    }
}
