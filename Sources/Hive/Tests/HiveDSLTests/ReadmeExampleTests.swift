import Foundation
import Testing
import HiveDSL

// MARK: - Test Infrastructure

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private func makeEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    model: AnyHiveModelClient? = nil,
    tools: AnyHiveToolRegistry? = nil,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: NoopClock(),
        logger: NoopLogger(),
        model: model,
        tools: tools,
        checkpointStore: checkpointStore
    )
}

private actor InMemoryCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.stepIndex < rhs.stepIndex
            }
    }
}

private actor RequestRecorder {
    private(set) var requests: [HiveChatRequest] = []
    func record(_ request: HiveChatRequest) { requests.append(request) }
}

private struct StubModelClient: HiveModelClient, Sendable {
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
        HiveToolResult(toolCallID: call.id, content: "stub-result")
    }
}

private func drainEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do { for try await event in stream { events.append(event) } } catch {}
    return events
}

// MARK: - README Example 1: Hello World

@Test("README Example: Hello World — minimal node sets a channel")
func readmeHelloWorldExample() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, String>(HiveChannelID("message"))
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

    let messageKey = HiveChannelKey<Schema, String>(HiveChannelID("message"))

    let workflow = Workflow<Schema> {
        Node("greet") { _ in
            Effects {
                Set(messageKey, "Hello from Hive!")
                End()
            }
        }.start()
    }

    let graph = try workflow.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
    let handle = await runtime.run(threadID: HiveThreadID("hello"), input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: HiveThreadID("hello")) else {
        #expect(Bool(false), "Store should exist after run")
        return
    }
    #expect(try store.get(messageKey) == "Hello from Hive!")
}

// MARK: - README Example 2: Branching

@Test("README Example: Branching — routes to 'pass' when score >= 70")
func readmeBranchingExample() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let scoreKey = HiveChannelKey<Schema, Int>(HiveChannelID("score"))
            let scoreSpec = HiveChannelSpec(
                key: scoreKey,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                persistence: .untracked
            )
            let resultKey = HiveChannelKey<Schema, String>(HiveChannelID("result"))
            let resultSpec = HiveChannelSpec(
                key: resultKey,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(scoreSpec), AnyHiveChannelSpec(resultSpec)]
        }
    }

    let scoreKey = HiveChannelKey<Schema, Int>(HiveChannelID("score"))
    let resultKey = HiveChannelKey<Schema, String>(HiveChannelID("result"))

    let workflow = Workflow<Schema> {
        Node("check") { _ in
            Effects { Set(scoreKey, 85); UseGraphEdges() }
        }.start()

        Node("pass") { _ in
            Effects { Set(resultKey, "passed"); End() }
        }
        Node("fail") { _ in
            Effects { Set(resultKey, "failed"); End() }
        }

        Branch(from: "check") {
            Branch.case(name: "high", when: { view in
                (try? view.get(scoreKey)) ?? 0 >= 70
            }) {
                GoTo("pass")
            }
            Branch.default { GoTo("fail") }
        }
    }

    let graph = try workflow.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
    let handle = await runtime.run(threadID: HiveThreadID("branch"), input: (), options: HiveRunOptions())

    let eventsTask = Task { await drainEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    // Verify the "pass" node was executed (score 85 >= 70)
    let executedNodes = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(nodeID, _) = event.kind else { return nil }
        return nodeID
    }
    #expect(executedNodes.contains(HiveNodeID("pass")))
    #expect(!executedNodes.contains(HiveNodeID("fail")))

    guard let store = await runtime.getLatestStore(threadID: HiveThreadID("branch")) else {
        #expect(Bool(false), "Store should exist after run")
        return
    }
    #expect(try store.get(resultKey) == "passed")
}

// MARK: - README Example 3: Agent Loop (ModelTurn)

@Test("README Example: Agent Loop — ModelTurn with tools writes answer")
func readmeAgentLoopExample() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, String>(HiveChannelID("answer"))
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

    let answerKey = HiveChannelKey<Schema, String>(HiveChannelID("answer"))
    let recorder = RequestRecorder()
    let response = HiveChatResponse(
        message: HiveChatMessage(id: "a1", role: .assistant, content: "72F and sunny")
    )
    let stub = StubModelClient(recorder: recorder, response: response)
    let tool = HiveToolDefinition(
        name: "weather",
        description: "Get weather",
        parametersJSONSchema: #"{"type":"object","properties":{}}"#
    )

    let workflow = Workflow<Schema> {
        ModelTurn("chat", model: "stub", messages: [
            HiveChatMessage(id: "u1", role: .user, content: "Weather in SF?")
        ])
        .tools(.environment)
        .writes(to: answerKey)
        .start()
    }

    let graph = try workflow.compile()
    let env: HiveEnvironment<Schema> = makeEnvironment(
        context: (),
        model: AnyHiveModelClient(stub),
        tools: AnyHiveToolRegistry(StubToolRegistry(tools: [tool]))
    )
    let runtime = HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(threadID: HiveThreadID("agent"), input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: HiveThreadID("agent")) else {
        #expect(Bool(false), "Store should exist after run")
        return
    }
    #expect(try store.get(answerKey) == "72F and sunny")
}

// MARK: - README Example 4: Fan-out + Join + Interrupt

@Test("README Example: Fan-out, Join, Interrupt — spawns workers, joins, interrupts, then resumes")
func readmeFanOutJoinInterruptExample() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let itemKey = HiveChannelKey<Schema, String>(HiveChannelID("item"))
            let itemSpec = HiveChannelSpec(
                key: itemKey,
                scope: .taskLocal,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                codec: HiveAnyCodec(HiveJSONCodec<String>()),
                persistence: .checkpointed
            )
            let resultsKey = HiveChannelKey<Schema, [String]>(HiveChannelID("results"))
            let resultsSpec = HiveChannelSpec(
                key: resultsKey,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                codec: HiveAnyCodec(HiveJSONCodec<[String]>()),
                persistence: .checkpointed
            )
            let doneKey = HiveChannelKey<Schema, String>(HiveChannelID("status"))
            let doneSpec = HiveChannelSpec(
                key: doneKey,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                codec: HiveAnyCodec(HiveJSONCodec<String>()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(itemSpec), AnyHiveChannelSpec(resultsSpec), AnyHiveChannelSpec(doneSpec)]
        }
    }

    let itemKey = HiveChannelKey<Schema, String>(HiveChannelID("item"))
    let resultsKey = HiveChannelKey<Schema, [String]>(HiveChannelID("results"))
    let statusKey = HiveChannelKey<Schema, String>(HiveChannelID("status"))

    let workflow = Workflow<Schema> {
        Node("dispatch") { _ in
            Effects {
                SpawnEach(["a", "b", "c"], node: "worker") { item in
                    var local = HiveTaskLocalStore<Schema>.empty
                    // Schema is known-valid; set cannot fail here.
                    try! local.set(itemKey, item)
                    return local
                }
                End()
            }
        }.start()

        Node("worker") { input in
            let item: String = try input.store.get(itemKey)
            return Effects {
                Append(resultsKey, elements: [item.uppercased()])
                End()
            }
        }

        Node("review") { _ in
            Effects { Interrupt("Approve results?") }
        }

        Node("done") { _ in
            Effects { Set(statusKey, "completed"); End() }
        }

        Join(parents: ["worker"], to: "review")
        Edge("review", to: "done")
    }

    let graph = try workflow.compile()
    let checkpointStore = InMemoryCheckpointStore<Schema>()
    let env = makeEnvironment(
        context: (),
        checkpointStore: AnyHiveCheckpointStore(checkpointStore)
    )
    let runtime = HiveRuntime(graph: graph, environment: env)
    let threadID = HiveThreadID("fanout")

    // Phase 1: Run until interrupt
    let handle = await runtime.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let eventsTask = Task { await drainEvents(handle.events) }
    let outcome = try await handle.outcome.value
    _ = await eventsTask.value

    guard case let .interrupted(interruption) = outcome else {
        #expect(Bool(false), "Expected interrupted outcome, got: \(outcome)")
        return
    }
    #expect(interruption.interrupt.payload == "Approve results?")

    // Verify workers produced results before interrupt
    guard let storeBeforeResume = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false), "Store should exist after interrupt")
        return
    }
    let resultsBefore = try storeBeforeResume.get(resultsKey)
    #expect(resultsBefore.count == 3)
    #expect(resultsBefore.sorted() == ["A", "B", "C"])

    // Phase 2: Resume after human approval
    let resumeHandle = await runtime.resume(
        threadID: threadID,
        interruptID: interruption.interrupt.id,
        payload: "approved",
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let resumeEventsTask = Task { await drainEvents(resumeHandle.events) }
    let resumeOutcome = try await resumeHandle.outcome.value
    _ = await resumeEventsTask.value

    guard case .finished = resumeOutcome else {
        #expect(Bool(false), "Expected finished outcome after resume, got: \(resumeOutcome)")
        return
    }

    guard let finalStore = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false), "Store should exist after resume")
        return
    }
    #expect(try finalStore.get(statusKey) == "completed")
    #expect(try finalStore.get(resultsKey).sorted() == ["A", "B", "C"])
}
