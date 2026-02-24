import CryptoKit
import Foundation
import Testing
@testable import HiveCore

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor StartLatch {
    private var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markStarted() {
        guard didStart == false else { return }
        didStart = true
        continuation?.resume()
        continuation = nil
    }

    func waitStarted() async {
        if didStart { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor InMemoryCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        // Latest = max stepIndex; tie-breaker is lexicographic ID (not needed for these tests).
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.stepIndex < rhs.stepIndex
            }
    }

    func all() async -> [HiveCheckpoint<Schema>] { checkpoints }
}

private actor BlockingCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    private enum WaitError: Error {
        case saveDidNotStartWithinTimeout
    }

    private var checkpoints: [HiveCheckpoint<Schema>] = []
    private var saveStarted = false

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        saveStarted = true
        while true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.stepIndex < rhs.stepIndex
            }
    }

    func waitForSaveStart(timeoutNanoseconds: UInt64 = 15_000_000_000) async throws {
        if saveStarted { return }

        var elapsed: UInt64 = 0
        while saveStarted == false {
            if elapsed >= timeoutNanoseconds {
                throw WaitError.saveDidNotStartWithinTimeout
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            elapsed += 1_000_000
        }
    }

    func all() async -> [HiveCheckpoint<Schema>] { checkpoints }
}

private func makeEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: NoopClock(),
        logger: NoopLogger(),
        checkpointStore: checkpointStore
    )
}

private func collectEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do {
        for try await event in stream { events.append(event) }
    } catch {
        return events
    }
    return events
}

private func collectEventsAndError(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> ([HiveEvent], Error?) {
    var events: [HiveEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private func sha256HexLower(_ data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
}

@Test("Interrupt selection by smallest taskOrdinal")
func testInterrupt_SelectsEarliestTaskOrdinal() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(interrupt: HiveInterruptRequest(payload: "A"))
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(interrupt: HiveInterruptRequest(payload: "B"))
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("interrupt-ordinal"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    guard case let .interrupted(interruption) = outcome else {
        #expect(Bool(false))
        return
    }

    #expect(interruption.interrupt.payload == "A")
    #expect(events.contains { event in
        if case let .runInterrupted(interruptID) = event.kind {
            return interruptID == interruption.interrupt.id
        }
        return false
    })
}

@Test("Interrupt ID derived from taskID")
func testInterruptID_DerivedFromTaskID() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(interrupt: HiveInterruptRequest(payload: "hi"))
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("interrupt-id"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    guard case let .interrupted(interruption) = outcome else {
        #expect(Bool(false))
        return
    }

    let taskID = events.compactMap { (event: HiveEvent) -> HiveTaskID? in
        guard case let .taskStarted(_, taskID) = event.kind else { return nil }
        return taskID
    }.first

    guard let taskID else { #expect(Bool(false)); return }

    var bytes = Data()
    bytes.append(contentsOf: "HINT1".utf8)
    bytes.append(contentsOf: taskID.rawValue.utf8)
    let expected = HiveInterruptID(sha256HexLower(bytes))

    #expect(interruption.interrupt.id == expected)
    #expect(events.contains { event in
        if case let .runInterrupted(interruptID) = event.kind {
            return interruptID == expected
        }
        return false
    })
}

@Test("Resume fails typed when no checkpoint exists")
func testResume_NoCheckpointToResume() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-no-checkpoint"),
        interruptID: HiveInterruptID("missing"),
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    do {
        _ = try await resumed.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .noCheckpointToResume:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

@Test("Resume fails typed when checkpoint has no pending interrupt")
func testResume_NoInterruptToResume() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let baseline = await runtime.run(
        threadID: HiveThreadID("resume-no-interrupt"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    _ = try await baseline.outcome.value

    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-no-interrupt"),
        interruptID: HiveInterruptID("unused"),
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    do {
        _ = try await resumed.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .noInterruptToResume:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

@Test("Resume fails typed on interrupt ID mismatch")
func testResume_InterruptIDMismatch() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .end, interrupt: HiveInterruptRequest(payload: "pause"))
    }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let initial = await runtime.run(
        threadID: HiveThreadID("resume-mismatch-id"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let interrupted = try await initial.outcome.value
    guard case let .interrupted(interruption) = interrupted else {
        #expect(Bool(false))
        return
    }

    let wrongInterruptID = HiveInterruptID("wrong-id")
    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-mismatch-id"),
        interruptID: wrongInterruptID,
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    do {
        _ = try await resumed.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case let .resumeInterruptMismatch(expected, found):
            #expect(expected == interruption.interrupt.id)
            #expect(found == wrongInterruptID)
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

@Test("Resume clears interruption only after first committed step")
func testResume_FirstCommitClearsInterruption() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .useGraphEdges, interrupt: HiveInterruptRequest(payload: "pause"))
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let initial = await runtime.run(
        threadID: HiveThreadID("resume-clear"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let interrupted = try await initial.outcome.value

    guard case let .interrupted(interruption) = interrupted else {
        #expect(Bool(false))
        return
    }

    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-clear"),
        interruptID: interruption.interrupt.id,
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    _ = try await resumed.outcome.value

    // Should not fail with interruptPending after the first resumed step commits.
    let subsequent = await runtime.run(
        threadID: HiveThreadID("resume-clear"),
        input: (),
        options: HiveRunOptions(maxSteps: 0, checkpointPolicy: .disabled)
    )
    _ = try await subsequent.outcome.value
}

@Test("Resume cancelled before first commit keeps interruption pending")
func testResume_CancelBeforeFirstCommit_KeepsInterruption() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = InMemoryCheckpointStore<Schema>()

    let latch = StartLatch()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .useGraphEdges, interrupt: HiveInterruptRequest(payload: "pause"))
    }
    builder.addNode(HiveNodeID("B")) { _ in
        await latch.markStarted()
        while Task.isCancelled == false {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CancellationError()
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let initial = await runtime.run(
        threadID: HiveThreadID("resume-cancel"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let interrupted = try await initial.outcome.value

    guard case let .interrupted(interruption) = interrupted else {
        #expect(Bool(false))
        return
    }

    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-cancel"),
        interruptID: interruption.interrupt.id,
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    await latch.waitStarted()

    // Cancel before the first step can commit.
    resumed.outcome.cancel()

    let resumeOutcome = try await resumed.outcome.value
    guard case .cancelled = resumeOutcome else { #expect(Bool(false)); return }

    // Interruption must remain pending.
    let subsequent = await runtime.run(
        threadID: HiveThreadID("resume-cancel"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    do {
        _ = try await subsequent.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .interruptPending:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }
}

@Test("Resume is visible only in the first resumed step")
func testResume_VisibleOnlyFirstStep() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let logKey = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))
            let spec = HiveChannelSpec(
                key: logKey,
                scope: .global,
                reducer: HiveReducer.append(),
                updatePolicy: .multi,
                initial: { [] },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let logKey = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .useGraphEdges, interrupt: HiveInterruptRequest(payload: "pause"))
    }
    builder.addNode(HiveNodeID("B")) { input in
        let saw = input.run.resume != nil
        return HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, [saw ? "B:saw" : "B:nil"])],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("C")) { input in
        let saw = input.run.resume != nil
        return HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, [saw ? "C:saw" : "C:nil"])],
            next: .end
        )
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    builder.addEdge(from: HiveNodeID("B"), to: HiveNodeID("C"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let initial = await runtime.run(
        threadID: HiveThreadID("resume-visible"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let interrupted = try await initial.outcome.value

    guard case let .interrupted(interruption) = interrupted else {
        #expect(Bool(false))
        return
    }

    let resumed = await runtime.resume(
        threadID: HiveThreadID("resume-visible"),
        interruptID: interruption.interrupt.id,
        payload: "resume",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    _ = try await resumed.outcome.value

    let latest = await runtime.getLatestStore(threadID: HiveThreadID("resume-visible"))
    guard let latest else { #expect(Bool(false)); return }
    #expect(try latest.get(logKey) == ["B:saw", "C:nil"])
}

@Test("Cold-start resume rebinds runID for newly persisted checkpoints")
func testResume_ColdStartRestore_RebindsRunIDForNewCheckpoint() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: valueKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(valueKey, 1)],
            next: .useGraphEdges,
            interrupt: HiveInterruptRequest(payload: "pause")
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 2)], next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let threadID = HiveThreadID("resume-cold-runid")

    let runtime1 = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let initial = await runtime1.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(checkpointPolicy: .onInterrupt)
    )
    let initialOutcome = try await initial.outcome.value
    guard case let .interrupted(interruption) = initialOutcome else {
        #expect(Bool(false))
        return
    }

    let checkpointsAfterInitial = await store.all()
    #expect(checkpointsAfterInitial.count == 1)
    let initialCheckpoint = try #require(checkpointsAfterInitial.max(by: { $0.stepIndex < $1.stepIndex }))
    let firstRunID = initialCheckpoint.runID

    let runtime2 = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let resumed = await runtime2.resume(
        threadID: threadID,
        interruptID: interruption.interrupt.id,
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let resumedOutcome = try await resumed.outcome.value
    guard case .finished = resumedOutcome else {
        #expect(Bool(false))
        return
    }

    let allCheckpoints = await store.all()
    let latest = try #require(allCheckpoints.max(by: { $0.stepIndex < $1.stepIndex }))
    #expect(latest.stepIndex == initialCheckpoint.stepIndex + 1)
    #expect(latest.runID == resumed.runID)
    #expect(latest.runID != firstRunID)
}

private struct IntCodec: HiveCodec {
    let id: String = "int.v1"
    func encode(_ value: Int) throws -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    func decode(_ data: Data) throws -> Int {
        guard data.count == MemoryLayout<Int>.size else { return 0 }
        return data.withUnsafeBytes { $0.load(as: Int.self) }.bigEndian
    }
}

@Test("applyExternalWrites increments stepIndex and keeps frontier")
func testApplyExternalWrites_IncrementsStepIndex_KeepsFrontier() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .useGraphEdges) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    // Commit one real step, then stop before consuming the next frontier.
    let firstRun = await runtime.run(
        threadID: HiveThreadID("ext-writes-frontier"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .disabled)
    )
    _ = try await firstRun.outcome.value

    let external = await runtime.applyExternalWrites(
        threadID: HiveThreadID("ext-writes-frontier"),
        writes: [AnyHiveWrite(valueKey, 123)],
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(external.events) }
    let outcome = try await external.outcome.value
    let events = await eventsTask.value

    guard case .finished = outcome else { #expect(Bool(false)); return }

    // Synthetic step runs at the current stepIndex and has empty frontier.
    #expect(events.contains { event in
        if case .stepStarted(stepIndex: 1, frontierCount: 0) = event.kind { return true }
        return false
    })
    #expect(events.contains { event in
        if case .stepFinished(stepIndex: 1, nextFrontierCount: 1) = event.kind { return true }
        return false
    })
    #expect(events.contains { event in
        if case .checkpointSaved = event.kind { return true }
        return false
    })

    // Checkpoint saved for external writes regardless of checkpointPolicy.
    let checkpoints = await store.all()
    #expect(checkpoints.count == 1)
    #expect(checkpoints[0].stepIndex == 2)
    #expect(checkpoints[0].frontier.count == 1)
    #expect(checkpoints[0].frontier[0].nodeID == HiveNodeID("B"))

    // The persisted frontier should execute at the incremented step index.
    let next = await runtime.run(
        threadID: HiveThreadID("ext-writes-frontier"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .disabled)
    )
    let nextEventsTask = Task { await collectEvents(next.events) }
    _ = try await next.outcome.value
    let nextEvents = await nextEventsTask.value
    #expect(nextEvents.contains { event in
        if case .stepStarted(stepIndex: 2, frontierCount: 1) = event.kind { return true }
        return false
    })
}

@Test("applyExternalWrites rejects task-local writes")
func testApplyExternalWrites_RejectsTaskLocalWrites() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let localKey = HiveChannelKey<Schema, Int>(HiveChannelID("local"))
            let spec = HiveChannelSpec(
                key: localKey,
                scope: .taskLocal,
                reducer: HiveReducer.lastWriteWins(),
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let localKey = HiveChannelKey<Schema, Int>(HiveChannelID("local"))
    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.applyExternalWrites(
        threadID: HiveThreadID("ext-writes-tasklocal"),
        writes: [AnyHiveWrite(localKey, 1)],
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveExternalWriteError {
        switch error {
        case .scopeMismatch(let channelID, let expected, let actual):
            #expect(channelID == HiveChannelID("local"))
            #expect(expected == .global)
            #expect(actual == .taskLocal)
        default:
            #expect(Bool(false))
        }
    }

    let (events, streamError) = await eventsTask.value
    #expect(streamError != nil)

    // No commit-scoped events should be emitted for a failed synthetic step.
    #expect(events.contains { if case .runStarted = $0.kind { return true }; return false })
    #expect(events.contains { if case .stepStarted = $0.kind { return true }; return false })
    #expect(!events.contains { if case .writeApplied = $0.kind { return true }; return false })
    #expect(!events.contains { if case .checkpointSaved = $0.kind { return true }; return false })
    #expect(!events.contains { if case .stepFinished = $0.kind { return true }; return false })

    let checkpoints = await store.all()
    #expect(checkpoints.isEmpty)
}

@Test("applyExternalWrites cancellation during checkpoint save yields cancelled with no commit")
func testApplyExternalWrites_CancelDuringCheckpointSave_ReturnsCancelledNoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: valueKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let store = BlockingCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.applyExternalWrites(
        threadID: HiveThreadID("ext-writes-cancel-save"),
        writes: [AnyHiveWrite(valueKey, 1)],
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    try await store.waitForSaveStart()
    handle.outcome.cancel()

    let outcome = try await handle.outcome.value
    let (events, streamError) = await eventsTask.value
    #expect(streamError == nil)

    guard case let .cancelled(output, checkpointID) = outcome else {
        #expect(Bool(false))
        return
    }
    #expect(checkpointID == nil)
    if case let .fullStore(storeOutput) = output {
        #expect(try storeOutput.get(valueKey) == 0)
    } else {
        #expect(Bool(false))
    }

    let checkpoints = await store.all()
    #expect(checkpoints.isEmpty)
    #expect(!events.contains { event in
        if case .writeApplied = event.kind { return true }
        if case .checkpointSaved = event.kind { return true }
        if case .stepFinished = event.kind { return true }
        return false
    })
    if let last = events.last {
        guard case .runCancelled(let cause) = last.kind else {
            #expect(Bool(false))
            return
        }
        #expect(cause == .checkpointPersistenceRace)
    } else {
        #expect(Bool(false))
    }
}

@Test("Cold-start applyExternalWrites rebinds runID for newly persisted checkpoints")
func testApplyExternalWrites_ColdStartRestore_RebindsRunIDForNewCheckpoint() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: valueKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let store = InMemoryCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 1)], next: .useGraphEdges)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let threadID = HiveThreadID("ext-writes-cold-runid")

    let runtime1 = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let first = await runtime1.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    _ = try await first.outcome.value

    let checkpointsAfterFirstRun = await store.all()
    #expect(checkpointsAfterFirstRun.count == 1)
    let firstCheckpoint = try #require(checkpointsAfterFirstRun.max(by: { $0.stepIndex < $1.stepIndex }))
    let firstRunID = firstCheckpoint.runID

    let runtime2 = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let external = await runtime2.applyExternalWrites(
        threadID: threadID,
        writes: [AnyHiveWrite(valueKey, 99)],
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    _ = try await external.outcome.value

    let allCheckpoints = await store.all()
    let latest = try #require(allCheckpoints.max(by: { $0.stepIndex < $1.stepIndex }))
    #expect(latest.stepIndex == 2)
    #expect(latest.runID == external.runID)
    #expect(latest.runID != firstRunID)
}
