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

private actor TestCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    var checkpoints: [HiveCheckpoint<Schema>] = []
    var loadError: Error?
    var saveError: Error?
    var override: HiveCheckpoint<Schema>?

    func setLoadError(_ error: Error?) { loadError = error }
    func setSaveError(_ error: Error?) { saveError = error }
    func setOverride(_ checkpoint: HiveCheckpoint<Schema>?) { override = checkpoint }

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        if let saveError { throw saveError }
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        if let loadError { throw loadError }
        if let override { return override }
        return checkpoints
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

private struct IntCodec: HiveCodec {
    let id: String

    func encode(_ value: Int) throws -> Data {
        Data(String(value).utf8)
    }

    func decode(_ data: Data) throws -> Int {
        guard let value = Int(String(decoding: data, as: UTF8.self)) else {
            throw TestError.decodeFailed
        }
        return value
    }
}

private struct FailingEncodeCodec: HiveCodec {
    let id: String

    func encode(_ value: Int) throws -> Data {
        throw TestError.encodeFailed
    }

    func decode(_ data: Data) throws -> Int {
        guard let value = Int(String(decoding: data, as: UTF8.self)) else {
            throw TestError.decodeFailed
        }
        return value
    }
}

private enum TestError: Error {
    case encodeFailed
    case decodeFailed
    case saveFailed
    case loadFailed
}

@Test("Checkpoint persists frontier order + provenance")
func testCheckpoint_PersistsFrontierOrderAndProvenance() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            spawn: [
                HiveTaskSeed(nodeID: HiveNodeID("D")),
                HiveTaskSeed(nodeID: HiveNodeID("E"))
            ],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("C")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("D")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("E")) { _ in HiveNodeOutput(next: .end) }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("C"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("frontier-order"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    _ = try await handle.outcome.value

    let checkpoints = await store.all()
    #expect(checkpoints.count == 1)
    let checkpoint = checkpoints[0]

    let nodes = checkpoint.frontier.map { $0.nodeID }
    #expect(nodes == [HiveNodeID("B"), HiveNodeID("C"), HiveNodeID("D"), HiveNodeID("E")])

    let provenance = checkpoint.frontier.map { $0.provenance }
    #expect(provenance == [.graph, .graph, .spawn, .spawn])
}

@Test("Checkpoint stepIndex is next step")
func testCheckpoint_StepIndexIsNextStep() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("step-index"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    _ = try await handle.outcome.value

    let checkpoints = await store.all()
    #expect(checkpoints.count == 1)
    #expect(checkpoints[0].stepIndex == 1)
}

@Test("Checkpoint ID derived from runID + stepIndex")
func testCheckpointID_DerivedFromRunIDAndStepIndex() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("checkpoint-id"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    _ = try await handle.outcome.value

    let checkpoints = await store.all()
    #expect(checkpoints.count == 1)
    let checkpoint = checkpoints[0]

    var bytes = Data()
    bytes.append(contentsOf: "HCP1".utf8)
    var uuid = checkpoint.runID.rawValue.uuid
    withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
    var step = UInt32(checkpoint.stepIndex).bigEndian
    withUnsafeBytes(of: &step) { bytes.append(contentsOf: $0) }
    let hash = SHA256.hash(data: bytes)
    let expected = hash.map { String(format: "%02x", $0) }.joined()

    #expect(checkpoint.id.rawValue == expected)
}

@Test("Cold-start checkpoint restore rebinds runID to the new handle runID")
func testRun_ColdStartRestore_RebindsRunIDForNewCheckpoint() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 1)], next: .useGraphEdges)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 1)], next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let threadID = HiveThreadID("runid-cold-start")

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

    let afterFirstRun = await store.all()
    #expect(afterFirstRun.count == 1)
    let firstCheckpoint = try #require(afterFirstRun.max(by: { $0.stepIndex < $1.stepIndex }))
    let firstRunID = firstCheckpoint.runID

    let runtime2 = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let second = await runtime2.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    _ = try await second.outcome.value

    let allCheckpoints = await store.all()
    let latest = try #require(allCheckpoints.max(by: { $0.stepIndex < $1.stepIndex }))
    #expect(latest.stepIndex == 2)
    #expect(latest.runID == second.runID)
    #expect(latest.runID != firstRunID)
}

@Test("Checkpoint resume parity matches uninterrupted run output")
func testCheckpointResumeParity_MatchesUninterruptedRun() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 1)], next: .useGraphEdges)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 2)], next: .end)
    }
    builder.addNode(HiveNodeID("C")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 3)], next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("C"))

    let graph = try builder.compile()

    let baselineRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: ())
    )
    let baseline = await baselineRuntime.run(
        threadID: HiveThreadID("checkpoint-parity-baseline"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let baselineOutcome = try await baseline.outcome.value
    guard case let .finished(output, _) = baselineOutcome else {
        #expect(Bool(false))
        return
    }
    guard case let .fullStore(baselineStore) = output else {
        #expect(Bool(false))
        return
    }
    let baselineValue = try baselineStore.get(valueKey)
    #expect(baselineValue == 6)

    let checkpointStore = TestCheckpointStore<Schema>()
    let checkpointedRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(checkpointStore))
    )

    let first = await checkpointedRuntime.run(
        threadID: HiveThreadID("checkpoint-parity"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    let firstOutcome = try await first.outcome.value
    guard case .outOfSteps = firstOutcome else {
        #expect(Bool(false))
        return
    }

    let checkpoints = await checkpointStore.all()
    #expect(!checkpoints.isEmpty)

    let resumedRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(checkpointStore))
    )
    let resumed = await resumedRuntime.run(
        threadID: HiveThreadID("checkpoint-parity"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let resumedOutcome = try await resumed.outcome.value
    guard case let .finished(resumedOutput, _) = resumedOutcome else {
        #expect(Bool(false))
        return
    }
    guard case let .fullStore(resumedStore) = resumedOutput else {
        #expect(Bool(false))
        return
    }
    let resumedValue = try resumedStore.get(valueKey)
    #expect(resumedValue == baselineValue)
}

@Test("Checkpoint preserves deferred frontier across resume")
func testCheckpoint_PreservesDeferredFrontierAcrossResume() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                initial: { [] },
                codec: HiveAnyCodec(HiveJSONCodec<[String]>()),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let logKey = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("main")])
    builder.addNode(HiveNodeID("main")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, ["main"])],
            next: .nodes([HiveNodeID("summary"), HiveNodeID("cleanup")])
        )
    }
    builder.addNode(HiveNodeID("summary")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, ["summary"])],
            next: .end
        )
    }
    builder.addNode(HiveNodeID("cleanup"), options: .deferred) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, ["cleanup"])],
            next: .end
        )
    }
    let graph = try builder.compile()

    let baselineRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: ())
    )
    let baselineHandle = await baselineRuntime.run(
        threadID: HiveThreadID("deferred-baseline"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let baselineOutcome = try await baselineHandle.outcome.value
    guard case let .finished(baselineOutput, _) = baselineOutcome,
          case let .fullStore(baselineStore) = baselineOutput else {
        #expect(Bool(false))
        return
    }
    let baselineLog = try baselineStore.get(logKey)
    #expect(baselineLog == ["main", "summary", "cleanup"])

    let checkpointStore = TestCheckpointStore<Schema>()
    let checkpointedRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(checkpointStore))
    )

    let first = await checkpointedRuntime.run(
        threadID: HiveThreadID("deferred-resume"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    let firstOutcome = try await first.outcome.value
    guard case .outOfSteps = firstOutcome else {
        #expect(Bool(false))
        return
    }

    let checkpoints = await checkpointStore.all()
    #expect(checkpoints.count == 1)
    #expect(checkpoints[0].frontier.map(\.nodeID) == [HiveNodeID("summary")])
    #expect(checkpoints[0].deferredFrontier.map(\.nodeID) == [HiveNodeID("cleanup")])

    let resumedRuntime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(checkpointStore))
    )
    let resumed = await resumedRuntime.run(
        threadID: HiveThreadID("deferred-resume"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    let resumedOutcome = try await resumed.outcome.value
    guard case let .finished(resumedOutput, _) = resumedOutcome,
          case let .fullStore(resumedStore) = resumedOutput else {
        #expect(Bool(false))
        return
    }
    let resumedLog = try resumedStore.get(logKey)
    #expect(resumedLog == baselineLog)
}

@Test("Checkpoint decode failure fails before step 0")
func testCheckpointDecodeFailure_FailsBeforeStep0() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let badCheckpoint = HiveCheckpoint<Schema>(
        id: HiveCheckpointID("bad"),
        threadID: HiveThreadID("decode-fail"),
        runID: HiveRunID(UUID()),
        stepIndex: 0,
        schemaVersion: graph.schemaVersion,
        graphVersion: graph.graphVersion,
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )

    await store.setOverride(badCheckpoint)

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("decode-fail"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointDecodeFailed(let channelID, _):
            #expect(channelID.rawValue == "value")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    #expect(!events.contains { event in
        if case .stepStarted = event.kind { return true }
        return false
    })
    #expect(!events.contains { event in
        if case .checkpointLoaded = event.kind { return true }
        return false
    })
}

@Test("Checkpoint corrupt join barrier keys mismatch fails before step 0")
func testCheckpointCorrupt_JoinBarrierKeysMismatch_FailsBeforeStep0() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("C")) { _ in HiveNodeOutput(next: .end) }
    builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("C"))
    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let corrupt = HiveCheckpoint<Schema>(
        id: HiveCheckpointID("bad"),
        threadID: HiveThreadID("join-corrupt"),
        runID: HiveRunID(UUID()),
        stepIndex: 0,
        schemaVersion: graph.schemaVersion,
        graphVersion: graph.graphVersion,
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )

    await store.setOverride(corrupt)

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("join-corrupt"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointCorrupt(let field, _):
            #expect(field == "joinBarrierSeenByJoinID")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    #expect(!events.contains { event in
        if case .stepStarted = event.kind { return true }
        return false
    })
    #expect(!events.contains { event in
        if case .checkpointLoaded = event.kind { return true }
        return false
    })
}

@Test("Checkpoint save failure aborts commit")
func testCheckpointSaveFailure_AbortsCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let store = TestCheckpointStore<Schema>()
    await store.setSaveError(TestError.saveFailed)

    let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(key, 1)], next: .end)
    }

    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("save-fail"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as TestError {
        #expect(error == .saveFailed)
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    let checkpoints = await store.all()
    #expect(checkpoints.isEmpty)
    let snapshot = await runtime.getLatestStore(threadID: HiveThreadID("save-fail"))
    if let snapshot {
        do {
            let value = try snapshot.get(key)
            #expect(value == 0)
        } catch {
            #expect(Bool(false))
        }
    } else {
        #expect(Bool(false))
    }
    #expect(!events.contains { event in
        if case .writeApplied = event.kind { return true }
        if case .checkpointSaved = event.kind { return true }
        if case .stepFinished = event.kind { return true }
        return false
    })
}

@Test("Cancellation during checkpoint save yields cancelled outcome and no commit")
func testCancellationDuringCheckpointSave_ReturnsCancelledNoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let store = BlockingCheckpointStore<Schema>()
    let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(key, 1)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let threadID = HiveThreadID("save-cancel")
    let handle = await runtime.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    try await store.waitForSaveStart()
    handle.outcome.cancel()

    let outcome = try await handle.outcome.value
    let events = await eventsTask.value
    let checkpoints = await store.all()

    guard case let .cancelled(output, checkpointID) = outcome else {
        #expect(Bool(false))
        return
    }
    #expect(checkpointID == nil)
    if case let .fullStore(storeOutput) = output {
        #expect(try storeOutput.get(key) == 0)
    } else {
        #expect(Bool(false))
    }

    #expect(checkpoints.isEmpty)
    let snapshot = await runtime.getLatestStore(threadID: threadID)
    #expect(snapshot != nil)
    if let snapshot {
        #expect(try snapshot.get(key) == 0)
    }

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

@Test("Checkpoint encode failure aborts commit deterministically")
func testCheckpointEncodeFailure_AbortsCommitDeterministically() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))
            let reducer = HiveReducer<Int> { current, update in current + update }

            let aSpec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: reducer,
                initial: { 0 },
                codec: HiveAnyCodec(FailingEncodeCodec(id: "fail")),
                persistence: .checkpointed
            )
            let bSpec = HiveChannelSpec(
                key: bKey,
                scope: .global,
                reducer: reducer,
                initial: { 0 },
                codec: HiveAnyCodec(FailingEncodeCodec(id: "fail")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(bSpec), AnyHiveChannelSpec(aSpec)]
        }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }

    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("encode-fail"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointEncodeFailed(let channelID, _):
            #expect(channelID.rawValue == "a")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    #expect(!events.contains { event in
        if case .writeApplied = event.kind { return true }
        if case .checkpointSaved = event.kind { return true }
        if case .stepFinished = event.kind { return true }
        return false
    })
}

@Test("Checkpoint load throws fails before step 0")
func testCheckpointLoadThrows_FailsBeforeStep0() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()
    await store.setLoadError(TestError.loadFailed)

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("load-throws"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as TestError {
        #expect(error == .loadFailed)
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    #expect(!events.contains { event in
        if case .stepStarted = event.kind { return true }
        return false
    })
    #expect(!events.contains { event in
        if case .checkpointLoaded = event.kind { return true }
        return false
    })
}

@Test("Resume version mismatch fails before step 0")
func testResume_VersionMismatchFailsBeforeStep0() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try? builder.compile()
    guard let graph else { #expect(Bool(false)); return }

    let interruption = HiveInterrupt<Schema>(
        id: HiveInterruptID("interrupt"),
        payload: "pause"
    )

    let mismatched = HiveCheckpoint<Schema>(
        id: HiveCheckpointID("bad"),
        threadID: HiveThreadID("resume-mismatch"),
        runID: HiveRunID(UUID()),
        stepIndex: 0,
        schemaVersion: "bad-schema",
        graphVersion: graph.graphVersion,
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: interruption
    )

    await store.setOverride(mismatched)

    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.resume(
        threadID: HiveThreadID("resume-mismatch"),
        interruptID: interruption.id,
        payload: "go",
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointVersionMismatch:
            break
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }

    let events = await eventsTask.value
    #expect(!events.contains { event in
        if case .stepStarted = event.kind { return true }
        return false
    })
    #expect(!events.contains { event in
        if case .checkpointLoaded = event.kind { return true }
        return false
    })
}
