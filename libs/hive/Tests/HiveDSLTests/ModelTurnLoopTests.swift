import Foundation
import Testing
import HiveDSL

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor ModelScript {
    private let responses: [HiveChatResponse]
    private var requests: [HiveChatRequest] = []
    private var cursor = 0

    init(responses: [HiveChatResponse]) {
        self.responses = responses
    }

    func nextResponse(for request: HiveChatRequest) throws -> HiveChatResponse {
        requests.append(request)
        guard cursor < responses.count else {
            throw HiveRuntimeError.modelStreamInvalid("Missing scripted response at index \(cursor)")
        }
        defer { cursor += 1 }
        return responses[cursor]
    }

    func allRequests() -> [HiveChatRequest] { requests }
}

private struct ScriptedModelClient: HiveModelClient, Sendable {
    let script: ModelScript

    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        try await script.nextResponse(for: request)
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

private actor ToolCallRecorder {
    private var calls: [HiveToolCall] = []

    func record(_ call: HiveToolCall) {
        calls.append(call)
    }

    func allCalls() -> [HiveToolCall] { calls }
}

private struct ScriptedToolRegistry: HiveToolRegistry, Sendable {
    let tools: [HiveToolDefinition]
    let recorder: ToolCallRecorder
    let contentByToolName: [String: String]

    func listTools() -> [HiveToolDefinition] { tools }

    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult {
        await recorder.record(call)
        let content = contentByToolName[call.name] ?? ""
        return HiveToolResult(toolCallID: call.id, content: content)
    }
}

private func makeLookupTool() -> HiveToolDefinition {
    HiveToolDefinition(
        name: "lookup",
        description: "Lookup by id",
        parametersJSONSchema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#
    )
}

@Test("ModelTurn default mode remains single-shot complete")
func modelTurnDefaultModeIsSingleShotComplete() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let out = HiveChannelKey<Schema, String>(HiveChannelID("out"))
            let spec = HiveChannelSpec(
                key: out,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let out = HiveChannelKey<Schema, String>(HiveChannelID("out"))
    let toolCall = HiveToolCall(id: "call-1", name: "lookup", argumentsJSON: #"{"id":"42"}"#)
    let firstAssistant = HiveChatMessage(
        id: "a1",
        role: .assistant,
        content: "need a tool",
        toolCalls: [toolCall]
    )

    let script = ModelScript(responses: [HiveChatResponse(message: firstAssistant)])
    let toolRecorder = ToolCallRecorder()
    let toolRegistry = ScriptedToolRegistry(
        tools: [makeLookupTool()],
        recorder: toolRecorder,
        contentByToolName: ["lookup": "unused"]
    )

    let workflow = Workflow<Schema> {
        ModelTurn(
            "mt",
            model: "stub",
            messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")]
        )
        .tools(.environment)
        .writes(to: out)
        .start()
    }

    let graph = try workflow.compile()
    let environment = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(ScriptedModelClient(script: script)),
        tools: AnyHiveToolRegistry(toolRegistry)
    )
    let runtime = HiveRuntime(graph: graph, environment: environment)
    let threadID = HiveThreadID("mt-default")
    let handle = await runtime.run(threadID: threadID, input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false))
        return
    }

    #expect(try store.get(out) == "need a tool")
    #expect((await script.allRequests()).count == 1)
    #expect((await toolRecorder.allCalls()).isEmpty)
}

@Test("ModelTurn agent loop executes tools and writes the final assistant answer")
func modelTurnAgentLoopExecutesToolsAndWritesFinalAnswer() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let out = HiveChannelKey<Schema, String>(HiveChannelID("out"))
            let spec = HiveChannelSpec(
                key: out,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let out = HiveChannelKey<Schema, String>(HiveChannelID("out"))
    let toolCall = HiveToolCall(id: "call-2", name: "lookup", argumentsJSON: #"{"id":"SF"}"#)
    let responses = [
        HiveChatResponse(
            message: HiveChatMessage(
                id: "a1",
                role: .assistant,
                content: "let me check",
                toolCalls: [toolCall]
            )
        ),
        HiveChatResponse(
            message: HiveChatMessage(
                id: "a2",
                role: .assistant,
                content: "Final answer: 72F"
            )
        )
    ]

    let script = ModelScript(responses: responses)
    let toolRecorder = ToolCallRecorder()
    let toolRegistry = ScriptedToolRegistry(
        tools: [makeLookupTool()],
        recorder: toolRecorder,
        contentByToolName: ["lookup": "72F"]
    )

    let workflow = Workflow<Schema> {
        ModelTurn(
            "mt",
            model: "stub",
            messages: [HiveChatMessage(id: "u1", role: .user, content: "Weather?")]
        )
        .tools(.environment)
        .agentLoop()
        .writes(to: out)
        .start()
    }

    let graph = try workflow.compile()
    let environment = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(ScriptedModelClient(script: script)),
        tools: AnyHiveToolRegistry(toolRegistry)
    )
    let runtime = HiveRuntime(graph: graph, environment: environment)
    let threadID = HiveThreadID("mt-loop")
    let handle = await runtime.run(threadID: threadID, input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false))
        return
    }

    #expect(try store.get(out) == "Final answer: 72F")

    let requests = await script.allRequests()
    #expect(requests.count == 2)
    #expect(requests.first?.tools.map(\.name) == ["lookup"])
    #expect(requests.last?.messages.map(\.role) == [.user, .assistant, .tool])

    let calls = await toolRecorder.allCalls()
    #expect(calls.map(\.id) == ["call-2"])
}

@Test("writesMessages appends assistant/tool/assistant in deterministic order")
func modelTurnWritesMessagesInDeterministicOrder() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let transcript = HiveChannelKey<Schema, [HiveChatMessage]>(HiveChannelID("messages"))
            let spec = HiveChannelSpec(
                key: transcript,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let transcript = HiveChannelKey<Schema, [HiveChatMessage]>(HiveChannelID("messages"))
    let toolCall = HiveToolCall(id: "call-3", name: "lookup", argumentsJSON: #"{"id":"abc"}"#)
    let responses = [
        HiveChatResponse(
            message: HiveChatMessage(
                id: "assistant-1",
                role: .assistant,
                content: "checking",
                toolCalls: [toolCall]
            )
        ),
        HiveChatResponse(
            message: HiveChatMessage(
                id: "assistant-2",
                role: .assistant,
                content: "done"
            )
        )
    ]

    let script = ModelScript(responses: responses)
    let toolRegistry = ScriptedToolRegistry(
        tools: [makeLookupTool()],
        recorder: ToolCallRecorder(),
        contentByToolName: ["lookup": "tool-output"]
    )

    let workflow = Workflow<Schema> {
        ModelTurn(
            "mt",
            model: "stub",
            messages: [HiveChatMessage(id: "u1", role: .user, content: "start")]
        )
        .tools(.environment)
        .agentLoop()
        .writesMessages(to: transcript)
        .start()
    }

    let graph = try workflow.compile()
    let environment = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(ScriptedModelClient(script: script)),
        tools: AnyHiveToolRegistry(toolRegistry)
    )
    let runtime = HiveRuntime(graph: graph, environment: environment)
    let threadID = HiveThreadID("mt-messages")
    let handle = await runtime.run(threadID: threadID, input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false))
        return
    }

    let written = try store.get(transcript)
    #expect(written.map(\.id) == ["assistant-1", "tool:call-3", "assistant-2"])
    #expect(written.map(\.role) == [.assistant, .tool, .assistant])
    #expect(written[1].name == "lookup")
    #expect(written[1].toolCallID == "call-3")
    #expect(written[1].content == "tool-output")
}

@Test("agent loop throws toolRegistryMissing when tool calls are returned without a registry")
func modelTurnAgentLoopThrowsWhenToolRegistryMissing() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let toolCall = HiveToolCall(id: "call-missing", name: "lookup", argumentsJSON: #"{}"#)
    let response = HiveChatResponse(
        message: HiveChatMessage(
            id: "a1",
            role: .assistant,
            content: "needs tool",
            toolCalls: [toolCall]
        )
    )
    let script = ModelScript(responses: [response])

    let workflow = Workflow<Schema> {
        ModelTurn(
            "mt",
            model: "stub",
            messages: [HiveChatMessage(id: "u1", role: .user, content: "run")]
        )
        .agentLoop()
        .start()
    }

    let graph = try workflow.compile()
    let environment = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(ScriptedModelClient(script: script))
    )

    let runtime = HiveRuntime(graph: graph, environment: environment)
    let handle = await runtime.run(threadID: HiveThreadID("mt-missing-tools"), input: (), options: HiveRunOptions())

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        #expect({
            if case .toolRegistryMissing = error { true } else { false }
        }())
    } catch {
        #expect(Bool(false))
    }
}
