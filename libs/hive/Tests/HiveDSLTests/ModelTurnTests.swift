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

private actor RequestRecorder {
    private(set) var requests: [HiveChatRequest] = []
    func record(_ request: HiveChatRequest) { requests.append(request) }
    func last() -> HiveChatRequest? { requests.last }
}

private struct StubHiveModelClient: HiveModelClient, Sendable {
    let recorder: RequestRecorder
    let response: HiveChatResponse

    func complete(_ request: HiveChatRequest) async throws -> HiveChatResponse {
        await recorder.record(request)
        return response
    }

    func stream(_ request: HiveChatRequest) -> AsyncThrowingStream<HiveChatStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(request)
                continuation.yield(.final(response))
                continuation.finish()
            }
        }
    }
}

private struct StubToolRegistry: HiveToolRegistry, Sendable {
    let tools: [HiveToolDefinition]
    func listTools() -> [HiveToolDefinition] { tools }
    func invoke(_ call: HiveToolCall) async throws -> HiveToolResult {
        throw HiveRuntimeError.toolRegistryMissing
    }
}

@Test("ModelTurn uses environment.model and writes output to channel")
func modelTurnWritesOutput() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, String>(HiveChannelID("out"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let outKey = HiveChannelKey<Schema, String>(HiveChannelID("out"))
    let recorder = RequestRecorder()
    let response = HiveChatResponse(message: HiveChatMessage(id: "m1", role: .assistant, content: "hello"))
    let stub = StubHiveModelClient(recorder: recorder, response: response)

    let workflow = Workflow<Schema> {
        ModelTurn("mt", model: "stub", messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")])
            .writes(to: outKey)
            .start()
    }

    let graph = try workflow.compile()
    let env = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(stub)
    )

    let runtime = HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(threadID: HiveThreadID("mt-1"), input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: HiveThreadID("mt-1")) else {
        #expect(Bool(false))
        return
    }
    #expect(try store.get(outKey) == "hello")

    let request = await recorder.last()
    #expect(request?.model == "stub")
    #expect(request?.messages.count == 1)
    #expect(request?.tools.isEmpty == true)
}

@Test("ModelTurn throws a clear error when model is missing")
func modelTurnThrowsWhenModelMissing() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let workflow = Workflow<Schema> {
        ModelTurn("mt", model: "stub", messages: [])
            .start()
    }

    let graph = try workflow.compile()
    let env = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger()
    )

    let runtime = HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(threadID: HiveThreadID("mt-missing"), input: (), options: HiveRunOptions())

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        #expect({
            if case .modelClientMissing = error { true } else { false }
        }())
    } catch {
        #expect(Bool(false))
    }
}

@Test("ModelTurn includes tool definitions when configured and environment.tools exists")
func modelTurnIncludesToolsFromEnvironment() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let recorder = RequestRecorder()
    let response = HiveChatResponse(message: HiveChatMessage(id: "m1", role: .assistant, content: "ok"))
    let stub = StubHiveModelClient(recorder: recorder, response: response)

    let tool = HiveToolDefinition(
        name: "search",
        description: "Search things",
        parametersJSONSchema: #"{"type":"object","properties":{},"required":[]}"#
    )

    let workflow = Workflow<Schema> {
        ModelTurn("mt", model: "stub", messages: [HiveChatMessage(id: "u1", role: .user, content: "hi")])
            .tools(.environment)
            .start()
    }

    let graph = try workflow.compile()
    let env = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(stub),
        tools: AnyHiveToolRegistry(StubToolRegistry(tools: [tool]))
    )

    let runtime = HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(threadID: HiveThreadID("mt-tools"), input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    let request = await recorder.last()
    #expect(request?.tools.map(\.name) == ["search"])
}
