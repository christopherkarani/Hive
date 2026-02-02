import Testing
@testable import HiveCore

private actor RequestRecorder {
    private(set) var requests: [HiveChatRequest] = []

    func record(_ request: HiveChatRequest) {
        requests.append(request)
    }

    func last() -> HiveChatRequest? {
        requests.last
    }
}

private struct RecordingModelClient: HiveModelClient, Sendable {
    let recorder: RequestRecorder
    let response: HiveChatResponse
    let streamChunks: [HiveChatStreamChunk]

    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        await recorder.record(request)
        return response
    }

    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(request)
                for chunk in streamChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

private func collectChunks(
    _ stream: AsyncThrowingStream<HiveChatStreamChunk, Error>
) async throws -> [HiveChatStreamChunk] {
    var chunks: [HiveChatStreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

private func expectToolDefinitionMatches(_ lhs: HiveToolDefinition, _ rhs: HiveToolDefinition) {
    #expect(lhs.name == rhs.name)
    #expect(lhs.description == rhs.description)
    #expect(lhs.parametersJSONSchema == rhs.parametersJSONSchema)
}

private func expectToolCallMatches(_ lhs: HiveToolCall, _ rhs: HiveToolCall) {
    #expect(lhs.id == rhs.id)
    #expect(lhs.name == rhs.name)
    #expect(lhs.argumentsJSON == rhs.argumentsJSON)
}

private func expectMessageMatches(_ lhs: HiveChatMessage, _ rhs: HiveChatMessage) {
    #expect(lhs.id == rhs.id)
    #expect(lhs.role == rhs.role)
    #expect(lhs.content == rhs.content)
    #expect(lhs.name == rhs.name)
    #expect(lhs.toolCallID == rhs.toolCallID)
    #expect(lhs.op == rhs.op)
    #expect(lhs.toolCalls.count == rhs.toolCalls.count)
    for (left, right) in zip(lhs.toolCalls, rhs.toolCalls) {
        expectToolCallMatches(left, right)
    }
}

private func expectRequestMatches(_ lhs: HiveChatRequest, _ rhs: HiveChatRequest) {
    #expect(lhs.model == rhs.model)
    #expect(lhs.messages.count == rhs.messages.count)
    #expect(lhs.tools.count == rhs.tools.count)
    for (left, right) in zip(lhs.messages, rhs.messages) {
        expectMessageMatches(left, right)
    }
    for (left, right) in zip(lhs.tools, rhs.tools) {
        expectToolDefinitionMatches(left, right)
    }
}

@Test("AnyHiveModelClient forwards complete")
func anyHiveModelClientForwardsComplete() async throws {
    let recorder = RequestRecorder()
    let message = HiveChatMessage(id: "msg-1", role: .assistant, content: "ok")
    let response = HiveChatResponse(message: message)
    let request = HiveChatRequest(model: "model-a", messages: [message], tools: [])
    let client = RecordingModelClient(recorder: recorder, response: response, streamChunks: [])
    let anyClient = AnyHiveModelClient(client)

    let result = try await anyClient.complete(request)
    #expect(result.message.content == response.message.content)
    if let recorded = await recorder.last() {
        expectRequestMatches(recorded, request)
    }
}

@Test("AnyHiveModelClient forwards stream")
func anyHiveModelClientForwardsStream() async throws {
    let recorder = RequestRecorder()
    let message = HiveChatMessage(id: "msg-2", role: .assistant, content: "done")
    let response = HiveChatResponse(message: message)
    let request = HiveChatRequest(model: "model-b", messages: [message], tools: [])
    let client = RecordingModelClient(
        recorder: recorder,
        response: response,
        streamChunks: [.token("hi"), .final(response)]
    )
    let anyClient = AnyHiveModelClient(client)

    let chunks = try await collectChunks(anyClient.stream(request))
    #expect(chunks.count == 2)
    if chunks.count == 2 {
        #expect({
            if case let .token(token) = chunks[0] { return token == "hi" }
            return false
        }())
        #expect({
            if case let .final(finalResponse) = chunks[1] {
                return finalResponse.message.content == response.message.content
            }
            return false
        }())
    }
    if let recorded = await recorder.last() {
        expectRequestMatches(recorded, request)
    }
}

private actor ToolInvocationRecorder {
    private(set) var lastCall: HiveToolCall?

    func record(_ call: HiveToolCall) {
        lastCall = call
    }
}

private struct RecordingToolRegistry: HiveToolRegistry, Sendable {
    let tools: [HiveToolDefinition]
    let recorder: ToolInvocationRecorder
    let result: HiveToolResult

    func listTools() -> [HiveToolDefinition] {
        tools
    }

    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult {
        await recorder.record(call)
        return result
    }
}

@Test("AnyHiveToolRegistry forwards listTools and invoke")
func anyHiveToolRegistryForwardsCalls() async throws {
    let tool = HiveToolDefinition(
        name: "echo",
        description: "Echo input",
        parametersJSONSchema: "{\"type\":\"object\"}"
    )
    let call = HiveToolCall(id: "call-1", name: "echo", argumentsJSON: "{\"text\":\"hi\"}")
    let result = HiveToolResult(toolCallID: call.id, content: "hi")
    let recorder = ToolInvocationRecorder()
    let registry = RecordingToolRegistry(tools: [tool], recorder: recorder, result: result)
    let anyRegistry = AnyHiveToolRegistry(registry)

    let listed = anyRegistry.listTools()
    #expect(listed.count == 1)
    #expect(listed.first?.name == tool.name)
    #expect(listed.first?.parametersJSONSchema == tool.parametersJSONSchema)

    let invoked = try await anyRegistry.invoke(call)
    #expect(invoked.toolCallID == result.toolCallID)
    #expect(invoked.content == result.content)

    if let recorded = await recorder.lastCall {
        expectToolCallMatches(recorded, call)
    }
}
