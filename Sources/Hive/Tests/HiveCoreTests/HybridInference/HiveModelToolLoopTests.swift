import Foundation
import Testing
@testable import HiveCore

private enum StubError: Error, Sendable {
    case exhaustedResponses
}

private actor ModelRequestRecorder {
    private(set) var requests: [HiveChatRequest] = []

    func record(_ request: HiveChatRequest) {
        requests.append(request)
    }

    func snapshot() -> [HiveChatRequest] {
        requests
    }
}

private actor ModelResponseQueue {
    private var responses: [HiveChatResponse]

    init(responses: [HiveChatResponse]) {
        self.responses = responses
    }

    func pop() throws -> HiveChatResponse {
        guard !responses.isEmpty else { throw StubError.exhaustedResponses }
        return responses.removeFirst()
    }
}

private actor ModelStreamQueue {
    private var streams: [[HiveChatStreamChunk]]

    init(streams: [[HiveChatStreamChunk]]) {
        self.streams = streams
    }

    func pop() throws -> [HiveChatStreamChunk] {
        guard !streams.isEmpty else { throw StubError.exhaustedResponses }
        return streams.removeFirst()
    }
}

private struct ScriptedModelClient: HiveModelClient, Sendable {
    let recorder: ModelRequestRecorder
    let queue: ModelResponseQueue

    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        await recorder.record(request)
        return try await queue.pop()
    }

    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(.final(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private struct ScriptedStreamingModelClient: HiveModelClient, Sendable {
    let recorder: ModelRequestRecorder
    let queue: ModelStreamQueue

    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        await recorder.record(request)
        let chunks = try await queue.pop()
        for chunk in chunks {
            if case let .final(response) = chunk {
                return response
            }
        }
        throw StubError.exhaustedResponses
    }

    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    await recorder.record(request)
                    let chunks = try await queue.pop()
                    for chunk in chunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private actor ToolCallRecorder {
    private(set) var calls: [HiveToolCall] = []

    func record(_ call: HiveToolCall) {
        calls.append(call)
    }

    func snapshot() -> [HiveToolCall] {
        calls
    }
}

private final class StreamKindCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [HiveStreamEventKind] = []

    func append(_ kind: HiveStreamEventKind) {
        lock.lock()
        kinds.append(kind)
        lock.unlock()
    }

    func snapshot() -> [HiveStreamEventKind] {
        lock.lock()
        defer { lock.unlock() }
        return kinds
    }
}

private struct RecordingToolRegistry: HiveToolRegistry, Sendable {
    let recorder: ToolCallRecorder

    func listTools() -> [HiveToolDefinition] {
        [
            HiveToolDefinition(
                name: "alpha",
                description: "alpha tool",
                parametersJSONSchema: #"{"type":"object"}"#
            ),
            HiveToolDefinition(
                name: "beta",
                description: "beta tool",
                parametersJSONSchema: #"{"type":"object"}"#
            ),
        ]
    }

    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult {
        await recorder.record(call)
        return HiveToolResult(toolCallID: call.id, content: "result:\(call.name):\(call.id)")
    }
}

private func makeRequest(messages: [HiveChatMessage], tools: [HiveToolDefinition] = []) -> HiveChatRequest {
    HiveChatRequest(model: "loop-model", messages: messages, tools: tools)
}

@Test("no tool calls performs one model invocation and completes immediately")
func modelToolLoop_noToolCalls_completesSingleInvocation() async throws {
    let recorder = ModelRequestRecorder()
    let queue = ModelResponseQueue(
        responses: [
            HiveChatResponse(message: HiveChatMessage(id: "a1", role: .assistant, content: "final", toolCalls: []))
        ]
    )
    let model = AnyHiveModelClient(ScriptedModelClient(recorder: recorder, queue: queue))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .complete,
        maxModelInvocations: 3,
        toolCallOrder: .asEmitted
    )

    let result = try await HiveModelToolLoop.run(
        request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")]),
        modelClient: model,
        toolRegistry: nil,
        configuration: configuration
    )

    let requests = await recorder.snapshot()
    #expect(requests.count == 1)
    #expect(result.finalResponse.message.id == "a1")
    #expect(result.finalResponse.message.content == "final")
    #expect(result.appendedMessages.map(\.id) == ["a1"])
}

@Test("tool call then final answer appends assistant/tool/assistant deterministically")
func modelToolLoop_toolThenFinal_appendsDeterministicConversation() async throws {
    let recorder = ModelRequestRecorder()
    let toolRecorder = ToolCallRecorder()
    let firstAssistant = HiveChatMessage(
        id: "a1",
        role: .assistant,
        content: "I will call a tool",
        toolCalls: [
            HiveToolCall(id: "call-1", name: "alpha", argumentsJSON: #"{"x":1}"#)
        ]
    )
    let finalAssistant = HiveChatMessage(
        id: "a2",
        role: .assistant,
        content: "done",
        toolCalls: []
    )
    let queue = ModelResponseQueue(
        responses: [
            HiveChatResponse(message: firstAssistant),
            HiveChatResponse(message: finalAssistant),
        ]
    )
    let model = AnyHiveModelClient(ScriptedModelClient(recorder: recorder, queue: queue))
    let tools = AnyHiveToolRegistry(RecordingToolRegistry(recorder: toolRecorder))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .complete,
        maxModelInvocations: 4,
        toolCallOrder: .asEmitted
    )

    let result = try await HiveModelToolLoop.run(
        request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "start")]),
        modelClient: model,
        toolRegistry: tools,
        configuration: configuration
    )

    let toolCalls = await toolRecorder.snapshot()
    #expect(toolCalls.map(\.id) == ["call-1"])
    #expect(result.appendedMessages.map(\.role) == [.assistant, .tool, .assistant])
    #expect(result.appendedMessages.map(\.id) == ["a1", "tool:call-1", "a2"])
    #expect(result.finalResponse.message.id == "a2")
}

@Test("missing tool registry when model emits tool calls throws toolRegistryMissing")
func modelToolLoop_missingToolRegistry_throwsToolRegistryMissing() async throws {
    let recorder = ModelRequestRecorder()
    let queue = ModelResponseQueue(
        responses: [
            HiveChatResponse(
                message: HiveChatMessage(
                    id: "a1",
                    role: .assistant,
                    content: "need tool",
                    toolCalls: [HiveToolCall(id: "call-1", name: "alpha", argumentsJSON: "{}")]
                )
            )
        ]
    )
    let model = AnyHiveModelClient(ScriptedModelClient(recorder: recorder, queue: queue))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .complete,
        maxModelInvocations: 2,
        toolCallOrder: .asEmitted
    )

    do {
        _ = try await HiveModelToolLoop.run(
            request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "start")]),
            modelClient: model,
            toolRegistry: nil,
            configuration: configuration
        )
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        #expect({
            if case .toolRegistryMissing = error { true } else { false }
        }())
    } catch {
        #expect(Bool(false))
    }
}

@Test("max model invocations exceeded throws dedicated loop-bound runtime error")
func modelToolLoop_maxModelInvocationsExceeded_throwsLoopBoundError() async throws {
    let recorder = ModelRequestRecorder()
    let toolRecorder = ToolCallRecorder()
    let queue = ModelResponseQueue(
        responses: [
            HiveChatResponse(
                message: HiveChatMessage(
                    id: "a1",
                    role: .assistant,
                    content: "tool first",
                    toolCalls: [HiveToolCall(id: "call-1", name: "alpha", argumentsJSON: "{}")]
                )
            ),
            HiveChatResponse(message: HiveChatMessage(id: "a2", role: .assistant, content: "would be final"))
        ]
    )
    let model = AnyHiveModelClient(ScriptedModelClient(recorder: recorder, queue: queue))
    let tools = AnyHiveToolRegistry(RecordingToolRegistry(recorder: toolRecorder))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .complete,
        maxModelInvocations: 1,
        toolCallOrder: .asEmitted
    )

    do {
        _ = try await HiveModelToolLoop.run(
            request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "start")]),
            modelClient: model,
            toolRegistry: tools,
            configuration: configuration
        )
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        #expect({
            if case .modelToolLoopMaxModelInvocationsExceeded(maxModelInvocations: 1) = error { true } else { false }
        }())
    } catch {
        #expect(Bool(false))
    }
}

@Test("byNameThenID executes tools in deterministic sorted order")
func modelToolLoop_byNameThenID_ordersToolCallsDeterministically() async throws {
    let recorder = ModelRequestRecorder()
    let toolRecorder = ToolCallRecorder()
    let firstAssistant = HiveChatMessage(
        id: "a1",
        role: .assistant,
        content: "multiple tools",
        toolCalls: [
            HiveToolCall(id: "2", name: "beta", argumentsJSON: #"{"v":2}"#),
            HiveToolCall(id: "3", name: "alpha", argumentsJSON: #"{"v":3}"#),
            HiveToolCall(id: "1", name: "alpha", argumentsJSON: #"{"v":1}"#),
        ]
    )
    let finalAssistant = HiveChatMessage(id: "a2", role: .assistant, content: "sorted done")
    let queue = ModelResponseQueue(
        responses: [
            HiveChatResponse(message: firstAssistant),
            HiveChatResponse(message: finalAssistant),
        ]
    )
    let model = AnyHiveModelClient(ScriptedModelClient(recorder: recorder, queue: queue))
    let tools = AnyHiveToolRegistry(RecordingToolRegistry(recorder: toolRecorder))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .complete,
        maxModelInvocations: 4,
        toolCallOrder: .byNameThenID
    )

    let result = try await HiveModelToolLoop.run(
        request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "start")]),
        modelClient: model,
        toolRegistry: tools,
        configuration: configuration
    )

    let recordedCalls = await toolRecorder.snapshot()
    #expect(recordedCalls.map(\.name) == ["alpha", "alpha", "beta"])
    #expect(recordedCalls.map(\.id) == ["1", "3", "2"])
    #expect(result.appendedMessages.map(\.id) == ["a1", "tool:1", "tool:3", "tool:2", "a2"])
}

@Test("stream mode emits model tokens and returns final response")
func modelToolLoop_streamMode_emitsTokensAndFinalResponse() async throws {
    let recorder = ModelRequestRecorder()
    let queue = ModelStreamQueue(
        streams: [[
            .token("hel"),
            .token("lo"),
            .final(HiveChatResponse(message: HiveChatMessage(id: "a1", role: .assistant, content: "hello")))
        ]]
    )
    let model = AnyHiveModelClient(ScriptedStreamingModelClient(recorder: recorder, queue: queue))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .stream,
        maxModelInvocations: 2,
        toolCallOrder: .asEmitted
    )
    let collector = StreamKindCollector()

    let result = try await HiveModelToolLoop.run(
        request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")]),
        modelClient: model,
        toolRegistry: nil,
        configuration: configuration,
        emitStream: { kind, _ in
            collector.append(kind)
        }
    )

    let events = collector.snapshot()
    #expect(events.count == 4)
    let tokens = events.compactMap { event -> String? in
        guard case let .modelToken(text) = event else { return nil }
        return text
    }
    #expect(tokens == ["hel", "lo"])
    #expect(result.finalResponse.message.id == "a1")
    #expect(result.appendedMessages.map(\.id) == ["a1"])
}

@Test("stream mode rejects token after final chunk")
func modelToolLoop_streamMode_tokenAfterFinal_throws() async throws {
    let recorder = ModelRequestRecorder()
    let queue = ModelStreamQueue(
        streams: [[
            .final(HiveChatResponse(message: HiveChatMessage(id: "a1", role: .assistant, content: "done"))),
            .token("late")
        ]]
    )
    let model = AnyHiveModelClient(ScriptedStreamingModelClient(recorder: recorder, queue: queue))
    let configuration = HiveModelToolLoopConfiguration(
        modelCallMode: .stream,
        maxModelInvocations: 1,
        toolCallOrder: .asEmitted
    )

    do {
        _ = try await HiveModelToolLoop.run(
            request: makeRequest(messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")]),
            modelClient: model,
            toolRegistry: nil,
            configuration: configuration
        )
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .modelStreamInvalid:
            break
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}
