import Foundation
import Testing
@testable import HiveCore

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws {}
}

private actor RecordingClock: HiveClock {
    private var sleeps: [UInt64] = []

    nonisolated func nowNanoseconds() -> UInt64 { 0 }

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
    }

    func snapshotSleeps() -> [UInt64] { sleeps }
}

private struct CancellationOnSleepClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { throw CancellationError() }
}

private func makeEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    clock: any HiveClock
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: clock,
        logger: NoopLogger()
    )
}

private func collectEventsAndError(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> ([HiveEvent], Error?) {
    var events: [HiveEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private actor BoolFlag {
    private(set) var value: Bool = false
    func setTrue() { value = true }
}

private struct MarkerError: Error, Equatable, Sendable {
    let id: String
}

private struct ReducerBoom: Error, Equatable, Sendable {}

@Test("Multiple task failures throw smallest taskOrdinal error")
func testMultipleTaskFailures_ThrowsEarliestOrdinalError() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let errorA = MarkerError(id: "A")
    let errorB = MarkerError(id: "B")

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in throw errorA }
    builder.addNode(HiveNodeID("B")) { _ in throw errorB }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("multi-task-failure"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
        return
    } catch let thrown as MarkerError {
        #expect(thrown == errorA)
    } catch {
        #expect(Bool(false))
        return
    }

    let (events, eventsError) = await eventsTask.value
    #expect(eventsError != nil)
    if let eventsError = eventsError as? MarkerError {
        #expect(eventsError == errorA)
    } else {
        #expect(Bool(false))
    }

    let failedOrdinals = events.compactMap { event -> Int? in
        guard case .taskFailed = event.kind else { return nil }
        return event.id.taskOrdinal
    }
    #expect(failedOrdinals == [0, 1])
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)
}

@Test("Commit-time validation precedence: unknownChannel beats updatePolicy")
func testCommitFailurePrecedence_UnknownChannelBeatsUpdatePolicy() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
            let spec = HiveChannelSpec(
                key: xKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
    let unknownKey = HiveChannelKey<Schema, Int>(HiveChannelID("unknown"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(unknownKey, 1), AnyHiveWrite(xKey, 1)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(xKey, 2)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("unknown-vs-update-policy"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
        return
    } catch let thrown as HiveRuntimeError {
        guard case let .unknownChannelID(id) = thrown else {
            #expect(Bool(false))
            return
        }
        #expect(id.rawValue == "unknown")
    } catch {
        #expect(Bool(false))
        return
    }

    let (events, eventsError) = await eventsTask.value
    #expect(eventsError != nil)
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)

    let store = await runtime.getLatestStore(threadID: HiveThreadID("unknown-vs-update-policy"))
    #expect(store != nil)
    if let store {
        let x = try store.get(xKey)
        #expect(x == 0)
    }
}

@Test("updatePolicy.single global violates across tasks and does not commit")
func testUpdatePolicySingle_GlobalViolatesAcrossTasks_FailsNoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
            let spec = HiveChannelSpec(
                key: xKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(xKey, 1)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(xKey, 2)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("single-global-across-tasks"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
        return
    } catch let thrown as HiveRuntimeError {
        guard case let .updatePolicyViolation(channelID, policy, writeCount) = thrown else {
            #expect(Bool(false))
            return
        }
        #expect(channelID.rawValue == "x")
        #expect(policy == .single)
        #expect(writeCount == 2)
    } catch {
        #expect(Bool(false))
        return
    }

    let (events, _) = await eventsTask.value
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)

    let store = await runtime.getLatestStore(threadID: HiveThreadID("single-global-across-tasks"))
    #expect(store != nil)
    if let store {
        let x = try store.get(xKey)
        #expect(x == 0)
    }
}

@Test("updatePolicy.single taskLocal allows across tasks (per-task enforcement)")
func testUpdatePolicySingle_TaskLocalPerTask_AllowsAcrossTasks() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            struct Int64BECodec: HiveCodec {
                typealias Value = Int
                let id: String = "int64.be"

                func encode(_ value: Int) throws -> Data {
                    var v = Int64(value).bigEndian
                    return withUnsafeBytes(of: &v) { Data($0) }
                }

                func decode(_ data: Data) throws -> Int {
                    guard data.count == MemoryLayout<Int64>.size else {
                        throw HiveRuntimeError.invalidRunOptions("bad int64 decode")
                    }
                    var v: Int64 = 0
                    _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0) }
                    return Int(Int64(bigEndian: v))
                }
            }

            let tKey = HiveChannelKey<Schema, Int>(HiveChannelID("t"))
            let spec = HiveChannelSpec(
                key: tKey,
                scope: .taskLocal,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                codec: HiveAnyCodec(Int64BECodec()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let tKey = HiveChannelKey<Schema, Int>(HiveChannelID("t"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(tKey, 1)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(tKey, 1)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("single-tasklocal-per-task"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    let outcome = try await handle.outcome.value

    let (events, eventsError) = await eventsTask.value
    #expect(eventsError == nil)

    guard case .finished = outcome else {
        #expect(Bool(false))
        return
    }
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false })
    if let last = events.last {
        guard case .runFinished = last.kind else {
            #expect(Bool(false))
            return
        }
    } else {
        #expect(Bool(false))
    }
}

@Test("Reducer throw aborts step and does not commit any channel")
func testReducerThrows_AbortsStep_NoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))

            let specA = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )

            let throwingReducer = HiveReducer<Int> { current, update in
                if update == 2 { throw ReducerBoom() }
                return current + update
            }
            let specB = HiveChannelSpec(
                key: bKey,
                scope: .global,
                reducer: throwingReducer,
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )

            return [AnyHiveChannelSpec(specA), AnyHiveChannelSpec(specB)]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
    let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1), AnyHiveWrite(bKey, 1)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(bKey, 2)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("reducer-throws"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
        return
    } catch is ReducerBoom {
        // Expected.
    } catch {
        #expect(Bool(false))
        return
    }

    let (events, eventsError) = await eventsTask.value
    #expect(eventsError != nil)
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)

    let store = await runtime.getLatestStore(threadID: HiveThreadID("reducer-throws"))
    #expect(store != nil)
    if let store {
        #expect(try store.get(aKey) == 0)
        #expect(try store.get(bKey) == 0)
    }
}

@Test("Out-of-steps stops without executing another step")
func testOutOfSteps_StopsWithoutExecutingAnotherStep() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
            let spec = HiveChannelSpec(
                key: xKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        // Keep scheduling work so maxSteps is the stop condition.
        HiveNodeOutput(writes: [AnyHiveWrite(xKey, 1)], next: .nodes([HiveNodeID("A")]))
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("out-of-steps"),
        input: (),
        options: HiveRunOptions(maxSteps: 1)
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    let outcome = try await handle.outcome.value
    let (events, eventsError) = await eventsTask.value

    #expect(eventsError == nil)

    guard case let .outOfSteps(maxSteps, output, checkpointID) = outcome else {
        #expect(Bool(false))
        return
    }
    #expect(maxSteps == 1)
    #expect(checkpointID == nil)

    let stepStartedIndexes = events.compactMap { event -> Int? in
        guard case let .stepStarted(stepIndex, _) = event.kind else { return nil }
        return stepIndex
    }
    #expect(stepStartedIndexes == [0])

    #expect(events.contains { event in
        guard case let .stepStarted(stepIndex, _) = event.kind else { return false }
        return stepIndex == 1
    } == false)

    if let last = events.last {
        guard case .runFinished = last.kind else {
            #expect(Bool(false))
            return
        }
    } else {
        #expect(Bool(false))
    }

    switch output {
    case .fullStore(let store):
        #expect(try store.get(xKey) == 1)
    case .channels:
        #expect(Bool(false))
    }
}

@Test("Deterministic retry backoff uses injected clock (no jitter)")
func testRetryPolicy_ExponentialBackoff_UsesDeterministicSchedule() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    actor AttemptCounter {
        var attempts: Int = 0
        func nextAttempt() -> Int {
            attempts += 1
            return attempts
        }
    }

    let counter = AttemptCounter()
    let clock = RecordingClock()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(
        HiveNodeID("A"),
        retryPolicy: .exponentialBackoff(
            initialNanoseconds: 10,
            factor: 2.0,
            maxAttempts: 3,
            maxNanoseconds: 1_000
        )
    ) { _ in
        let attempt = await counter.nextAttempt()
        if attempt < 3 {
            throw MarkerError(id: "fail-\(attempt)")
        }
        return HiveNodeOutput(next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: clock))

    let handle = await runtime.run(
        threadID: HiveThreadID("retry-backoff"),
        input: (),
        options: HiveRunOptions()
    )

    let outcome = try await handle.outcome.value
    guard case .finished = outcome else {
        #expect(Bool(false))
        return
    }

    let sleeps = await clock.snapshotSleeps()
    #expect(sleeps == [10, 20])
}

@Test("CancellationError during retry backoff cancels the step and cancels other in-flight tasks")
func testRetryBackoff_CancellationErrorFromClock_TreatedAsCancellation_CancelsOtherTasks() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    actor AttemptCounter {
        var attempts: Int = 0
        func nextAttempt() -> Int {
            attempts += 1
            return attempts
        }
    }

    let counter = AttemptCounter()
    let didObserveCancellation = BoolFlag()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(
        HiveNodeID("A"),
        retryPolicy: .exponentialBackoff(
            initialNanoseconds: 1,
            factor: 2.0,
            maxAttempts: 2,
            maxNanoseconds: 1_000
        )
    ) { _ in
        let attempt = await counter.nextAttempt()
        if attempt == 1 {
            throw MarkerError(id: "trigger-backoff")
        }
        return HiveNodeOutput(next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        do {
            // Spin briefly until cancelled; if not cancelled, return successfully.
            for _ in 0..<200 {
                if Task.isCancelled {
                    await didObserveCancellation.setTrue()
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 100_000)
            }
            return HiveNodeOutput(next: .end)
        } catch is CancellationError {
            await didObserveCancellation.setTrue()
            throw CancellationError()
        }
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: CancellationOnSleepClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("cancel-on-backoff"),
        input: (),
        options: HiveRunOptions(maxConcurrentTasks: 2)
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    let outcome = try await handle.outcome.value
    let (events, eventsError) = await eventsTask.value

    #expect(eventsError == nil)

    guard case .cancelled = outcome else {
        #expect(Bool(false))
        return
    }

    // During-step cancellation: taskFailed for every frontier task in ascending ordinal, no commit-scoped events.
    let failedOrdinals = events.compactMap { event -> Int? in
        guard case .taskFailed = event.kind else { return nil }
        return event.id.taskOrdinal
    }
    #expect(failedOrdinals == [0, 1])
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    if let last = events.last {
        guard case .runCancelled = last.kind else {
            #expect(Bool(false))
            return
        }
    } else {
        #expect(Bool(false))
        return
    }

    let observed = await didObserveCancellation.value
    #expect(observed == true)
}

@Test("Cancellation during a step emits taskFailed for all frontier tasks and does not commit")
func testCancellationDuringStep_EmitsTaskFailedForAllFrontierTasks_InOrdinalOrder_NoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
            let spec = HiveChannelSpec(
                key: xKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let xKey = HiveChannelKey<Schema, Int>(HiveChannelID("x"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return HiveNodeOutput(writes: [AnyHiveWrite(xKey, 1)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return HiveNodeOutput(writes: [AnyHiveWrite(xKey, 2)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: (), clock: NoopClock()))

    let handle = await runtime.run(
        threadID: HiveThreadID("cancel-during-step"),
        input: (),
        options: HiveRunOptions(maxConcurrentTasks: 2)
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }

    // Allow the step to start, then cancel the run task (cancellation is not an error).
    try await Task.sleep(nanoseconds: 50_000_000)
    handle.outcome.cancel()

    let outcome = try await handle.outcome.value
    let (events, eventsError) = await eventsTask.value

    #expect(eventsError == nil)
    guard case .cancelled = outcome else {
        #expect(Bool(false))
        return
    }

    let failedOrdinals = events.compactMap { event -> Int? in
        guard case .taskFailed = event.kind else { return nil }
        return event.id.taskOrdinal
    }
    #expect(failedOrdinals == [0, 1])

    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)
    if let last = events.last {
        guard case .runCancelled = last.kind else {
            #expect(Bool(false))
            return
        }
    } else {
        #expect(Bool(false))
        return
    }

    let store = await runtime.getLatestStore(threadID: HiveThreadID("cancel-during-step"))
    #expect(store != nil)
    if let store {
        #expect(try store.get(xKey) == 0)
    }
}
