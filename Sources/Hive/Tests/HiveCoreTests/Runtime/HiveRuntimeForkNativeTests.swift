import CryptoKit
import Foundation
import Testing
@testable import HiveCore

private struct ForkClock: HiveClock {
    let now: UInt64

    func nowNanoseconds() -> UInt64 { now }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct ForkLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor ForkQueryableStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.stepIndex < rhs.stepIndex
            }
    }

    func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] {
        var summaries = checkpoints
            .filter { $0.threadID == threadID }
            .map {
                HiveCheckpointSummary(
                    id: $0.id,
                    threadID: $0.threadID,
                    runID: $0.runID,
                    stepIndex: $0.stepIndex,
                    schemaVersion: $0.schemaVersion,
                    graphVersion: $0.graphVersion
                )
            }
        summaries.sort {
            if $0.stepIndex == $1.stepIndex {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.stepIndex > $1.stepIndex
        }
        if let limit {
            return Array(summaries.prefix(limit))
        }
        return summaries
    }

    func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints.first { $0.threadID == threadID && $0.id == id }
    }

    func all() async -> [HiveCheckpoint<Schema>] { checkpoints }

    func seed(_ checkpoint: HiveCheckpoint<Schema>) async {
        checkpoints.append(checkpoint)
    }
}

private actor ForkNonQueryableStore<Schema: HiveSchema>: HiveCheckpointStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.stepIndex < rhs.stepIndex
            }
    }

    func all() async -> [HiveCheckpoint<Schema>] { checkpoints }
}

private func makeForkEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    nowNanoseconds: UInt64 = 0,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: ForkClock(now: nowNanoseconds),
        logger: ForkLogger(),
        checkpointStore: checkpointStore
    )
}

private func drainEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
    } catch {}
    return events
}

private func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.compactMap { String(format: "%02x", $0) }.joined()
}

private func stableEventBytes(_ events: [HiveEvent]) -> Data {
    let lines = events.map { event -> String in
        switch event.kind {
        case let .forkStarted(sourceThreadID, targetThreadID, sourceCheckpointID):
            let sourceID = sourceCheckpointID?.rawValue ?? "nil"
            return "started|\(sourceThreadID.rawValue)|\(targetThreadID.rawValue)|\(sourceID)"
        case let .forkCompleted(sourceThreadID, targetThreadID, sourceCheckpointID, targetCheckpointID):
            let targetID = targetCheckpointID?.rawValue ?? "nil"
            return "completed|\(sourceThreadID.rawValue)|\(targetThreadID.rawValue)|\(sourceCheckpointID.rawValue)|\(targetID)"
        case let .forkFailed(sourceThreadID, targetThreadID, sourceCheckpointID, errorCode):
            let sourceID = sourceCheckpointID?.rawValue ?? "nil"
            return "failed|\(sourceThreadID.rawValue)|\(targetThreadID.rawValue)|\(sourceID)|\(errorCode)"
        default:
            return "other"
        }
    }
    return Data(lines.joined(separator: "\n").utf8)
}

private enum ForkBaseSchema: HiveSchema {
    typealias Input = Int
    typealias InterruptPayload = String
    typealias ResumePayload = String

    enum Channels {
        static let value = HiveChannelKey<ForkBaseSchema, Int>(HiveChannelID("value"))
        static let notes = HiveChannelKey<ForkBaseSchema, [String]>(HiveChannelID("notes"))
    }

    static var channelSpecs: [AnyHiveChannelSpec<ForkBaseSchema>] {
        [
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: Channels.value,
                    scope: .global,
                    reducer: .sum(),
                    updatePolicy: .multi,
                    initial: { 0 },
                    codec: HiveAnyCodec(HiveJSONCodec<Int>(id: "value.codec")),
                    persistence: .checkpointed
                )
            ),
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: Channels.notes,
                    scope: .global,
                    reducer: .append(),
                    updatePolicy: .multi,
                    initial: { [] },
                    codec: HiveAnyCodec(HiveJSONCodec<[String]>(id: "notes.codec")),
                    persistence: .checkpointed
                )
            )
        ]
    }

    static func inputWrites(_ input: Int, inputContext: HiveInputContext) throws -> [AnyHiveWrite<ForkBaseSchema>] {
        guard input != 0 else { return [] }
        return [AnyHiveWrite(Channels.value, input)]
    }
}

private func makeForkGraph() throws -> CompiledHiveGraph<ForkBaseSchema> {
    var builder = HiveGraphBuilder<ForkBaseSchema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [
                AnyHiveWrite(ForkBaseSchema.Channels.value, 1),
                AnyHiveWrite(ForkBaseSchema.Channels.notes, ["A"])
            ],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("B")) { input in
        let tag: String
        if let resume = input.run.resume {
            tag = "B-resume:\(resume.payload)"
        } else {
            tag = "B"
        }

        return HiveNodeOutput(
            writes: [
                AnyHiveWrite(ForkBaseSchema.Channels.value, 10),
                AnyHiveWrite(ForkBaseSchema.Channels.notes, [tag])
            ],
            next: .end
        )
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    return try builder.compile()
}

private func makeInterruptGraph() throws -> CompiledHiveGraph<ForkBaseSchema> {
    var builder = HiveGraphBuilder<ForkBaseSchema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(ForkBaseSchema.Channels.notes, ["A-interrupt"])],
            next: .nodes([HiveNodeID("B")]),
            interrupt: HiveInterruptRequest(payload: "approve")
        )
    }
    builder.addNode(HiveNodeID("B")) { input in
        let payload = input.run.resume?.payload ?? "missing"
        return HiveNodeOutput(
            writes: [AnyHiveWrite(ForkBaseSchema.Channels.notes, ["B:\(payload)"])],
            next: .end
        )
    }
    return try builder.compile()
}

private func seedCheckpointForSource(
    runtime: HiveRuntime<ForkBaseSchema>,
    sourceThreadID: HiveThreadID,
    checkpointPolicy: HiveCheckpointPolicy = .everyStep
) async throws -> HiveCheckpointID {
    let handle = await runtime.run(
        threadID: sourceThreadID,
        input: 0,
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: checkpointPolicy)
    )
    _ = try await handle.outcome.value
    _ = await drainEvents(handle.events)

    guard let checkpoint = try await runtime.getLatestCheckpoint(threadID: sourceThreadID) else {
        struct MissingCheckpoint: Error {}
        throw MissingCheckpoint()
    }
    return checkpoint.id
}

@Test("fork from latest checkpoint clones thread state")
func testFork_FromLatestCheckpoint() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-latest")
    let targetThreadID = HiveThreadID("target-latest")
    let sourceCheckpointID = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    let forkResult = try await runtime.fork(
        threadID: sourceThreadID,
        to: targetThreadID
    )

    #expect(forkResult.sourceThreadID == sourceThreadID)
    #expect(forkResult.sourceCheckpointID == sourceCheckpointID)
    #expect(forkResult.targetThreadID == targetThreadID)
    #expect(forkResult.targetCheckpointID == nil)

    let sourceState = try await runtime.getState(threadID: sourceThreadID)
    let targetState = try await runtime.getState(threadID: targetThreadID)

    #expect(sourceState != nil)
    #expect(targetState != nil)
    #expect(sourceState?.stepIndex == targetState?.stepIndex)
    #expect(sourceState?.nextNodes == targetState?.nextNodes)

    let sourceValue = try sourceState?.store.get(ForkBaseSchema.Channels.value)
    let targetValue = try targetState?.store.get(ForkBaseSchema.Channels.value)
    #expect(sourceValue == targetValue)
}

@Test("fork from explicit checkpoint id")
func testFork_FromExplicitCheckpointID() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-explicit")
    let targetThreadID = HiveThreadID("target-explicit")
    let checkpointID = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    let forkResult = try await runtime.fork(
        threadID: sourceThreadID,
        to: targetThreadID,
        from: checkpointID
    )

    #expect(forkResult.sourceCheckpointID == checkpointID)
    #expect(forkResult.targetThreadID == targetThreadID)
}

@Test("fork target is isolated from source after subsequent run")
func testFork_SourceTargetIsolationAfterRun() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-isolation")
    let targetThreadID = HiveThreadID("target-isolation")
    _ = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    _ = try await runtime.fork(threadID: sourceThreadID, to: targetThreadID)

    let runTarget = await runtime.run(
        threadID: targetThreadID,
        input: 0,
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    _ = try await runTarget.outcome.value
    _ = await drainEvents(runTarget.events)

    let sourceState = try await runtime.getState(threadID: sourceThreadID)
    let targetState = try await runtime.getState(threadID: targetThreadID)

    let sourceValue = try sourceState?.store.get(ForkBaseSchema.Channels.value)
    let targetValue = try targetState?.store.get(ForkBaseSchema.Channels.value)

    #expect(sourceValue == 1)
    #expect(targetValue == 11)
}

@Test("fork with interruption can resume target")
func testFork_InterruptThenResumeTarget() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeInterruptGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-interrupt")
    let initial = await runtime.run(
        threadID: sourceThreadID,
        input: 0,
        options: HiveRunOptions(checkpointPolicy: .onInterrupt)
    )

    let initialOutcome = try await initial.outcome.value
    _ = await drainEvents(initial.events)

    guard case let .interrupted(interruption) = initialOutcome else {
        Issue.record("Expected interrupted outcome")
        return
    }

    let forkResult = try await runtime.fork(
        threadID: sourceThreadID,
        to: HiveThreadID("target-interrupt"),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    #expect(forkResult.targetCheckpointID != nil)

    let resumed = await runtime.resume(
        threadID: HiveThreadID("target-interrupt"),
        interruptID: interruption.interrupt.id,
        payload: "approved",
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    let resumedOutcome = try await resumed.outcome.value
    _ = await drainEvents(resumed.events)

    guard case .finished = resumedOutcome else {
        Issue.record("Expected finished outcome after target resume")
        return
    }

    let targetState = try await runtime.getState(threadID: HiveThreadID("target-interrupt"))
    let notes = try targetState?.store.get(ForkBaseSchema.Channels.notes) ?? []
    #expect(notes.contains("B:approved"))
}

@Test("fork then applyExternalWrites mutates target only")
func testFork_ApplyExternalWritesTargetOnly() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-ext")
    let targetThreadID = HiveThreadID("target-ext")
    _ = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    _ = try await runtime.fork(threadID: sourceThreadID, to: targetThreadID)

    let writes: [AnyHiveWrite<ForkBaseSchema>] = [AnyHiveWrite(ForkBaseSchema.Channels.value, 100)]
    let apply = await runtime.applyExternalWrites(
        threadID: targetThreadID,
        writes: writes,
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    _ = try await apply.outcome.value
    _ = await drainEvents(apply.events)

    let sourceState = try await runtime.getState(threadID: sourceThreadID)
    let targetState = try await runtime.getState(threadID: targetThreadID)

    let sourceValue = try sourceState?.store.get(ForkBaseSchema.Channels.value)
    let targetValue = try targetState?.store.get(ForkBaseSchema.Channels.value)

    #expect(sourceValue == 1)
    #expect(targetValue == 101)
}

@Test("fork fails when checkpoint store missing")
func testFork_FailsCheckpointStoreMissing() async throws {
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: ())
    )

    do {
        _ = try await runtime.fork(
            threadID: HiveThreadID("source"),
            to: HiveThreadID("target")
        )
        Issue.record("Expected forkCheckpointStoreMissing")
    } catch let error as HiveRuntimeError {
        guard case .forkCheckpointStoreMissing = error else {
            Issue.record("Expected forkCheckpointStoreMissing, got \(error)")
            return
        }
    }
}

@Test("fork validates request options")
func testFork_FailsInvalidRunOptions() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    do {
        _ = try await runtime.fork(
            threadID: HiveThreadID("source-invalid-options"),
            to: HiveThreadID("target-invalid-options"),
            options: HiveRunOptions(maxConcurrentTasks: 0)
        )
        Issue.record("Expected invalid bounds validation error")
    } catch let error as HiveRunOptionsValidationError {
        guard case .invalidBounds(let option, _) = error else {
            Issue.record("Expected invalidBounds, got \(error)")
            return
        }
        #expect(option == "maxConcurrentTasks")
    }
}

@Test("fork fails when source checkpoint missing")
func testFork_FailsSourceCheckpointMissing() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    do {
        _ = try await runtime.fork(
            threadID: HiveThreadID("missing-source"),
            to: HiveThreadID("target")
        )
        Issue.record("Expected forkSourceCheckpointMissing")
    } catch let error as HiveRuntimeError {
        guard case let .forkSourceCheckpointMissing(threadID, checkpointID) = error else {
            Issue.record("Expected forkSourceCheckpointMissing, got \(error)")
            return
        }
        #expect(threadID == HiveThreadID("missing-source"))
        #expect(checkpointID == nil)
    }
}

@Test("fork fails when checkpoint query unsupported for explicit checkpoint")
func testFork_FailsCheckpointQueryUnsupported() async throws {
    let store = ForkNonQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-no-query")
    let handle = await runtime.run(
        threadID: sourceThreadID,
        input: 0,
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    _ = try await handle.outcome.value
    _ = await drainEvents(handle.events)

    let explicitID = HiveCheckpointID("explicit-id")

    do {
        _ = try await runtime.fork(
            threadID: sourceThreadID,
            to: HiveThreadID("target-no-query"),
            from: explicitID
        )
        Issue.record("Expected forkCheckpointQueryUnsupported")
    } catch let error as HiveRuntimeError {
        guard case .forkCheckpointQueryUnsupported = error else {
            Issue.record("Expected forkCheckpointQueryUnsupported, got \(error)")
            return
        }
    }
}

@Test("fork fails on malformed checkpoint payload")
func testFork_FailsMalformedCheckpointPayload() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let malformed = HiveCheckpoint<ForkBaseSchema>(
        id: HiveCheckpointID("malformed"),
        threadID: HiveThreadID("source-malformed"),
        runID: HiveRunID(UUID()),
        stepIndex: 1,
        schemaVersion: graph.schemaVersion,
        graphVersion: graph.graphVersion,
        checkpointFormatVersion: "HCP2",
        channelVersionsByChannelID: [:],
        versionsSeenByNodeID: [:],
        updatedChannelsLastCommit: [],
        globalDataByChannelID: [:],
        frontier: [],
        deferredFrontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
    await store.seed(malformed)

    do {
        _ = try await runtime.fork(
            threadID: HiveThreadID("source-malformed"),
            to: HiveThreadID("target-malformed")
        )
        Issue.record("Expected forkMalformedCheckpoint")
    } catch let error as HiveRuntimeError {
        guard case let .forkMalformedCheckpoint(field, _) = error else {
            Issue.record("Expected forkMalformedCheckpoint, got \(error)")
            return
        }
        #expect(!field.isEmpty)
    }
}

@Test("fork fails on schema or graph mismatch")
func testFork_FailsSchemaGraphMismatch() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let mismatched = HiveCheckpoint<ForkBaseSchema>(
        id: HiveCheckpointID("mismatch"),
        threadID: HiveThreadID("source-mismatch"),
        runID: HiveRunID(UUID()),
        stepIndex: 1,
        schemaVersion: "bad-schema",
        graphVersion: graph.graphVersion,
        checkpointFormatVersion: "HCP2",
        channelVersionsByChannelID: [:],
        versionsSeenByNodeID: [:],
        updatedChannelsLastCommit: [],
        globalDataByChannelID: [:],
        frontier: [],
        deferredFrontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
    await store.seed(mismatched)

    do {
        _ = try await runtime.fork(
            threadID: HiveThreadID("source-mismatch"),
            to: HiveThreadID("target-mismatch")
        )
        Issue.record("Expected forkSchemaGraphMismatch")
    } catch let error as HiveRuntimeError {
        guard case .forkSchemaGraphMismatch = error else {
            Issue.record("Expected forkSchemaGraphMismatch, got \(error)")
            return
        }
    }
}

@Test("fork rejects target thread conflicts")
func testFork_FailsTargetThreadConflict() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-conflict")
    _ = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    _ = try await runtime.fork(threadID: sourceThreadID, to: HiveThreadID("target-conflict"))

    do {
        _ = try await runtime.fork(threadID: sourceThreadID, to: HiveThreadID("target-conflict"))
        Issue.record("Expected forkTargetThreadConflict")
    } catch let error as HiveRuntimeError {
        guard case let .forkTargetThreadConflict(threadID) = error else {
            Issue.record("Expected forkTargetThreadConflict, got \(error)")
            return
        }
        #expect(threadID == HiveThreadID("target-conflict"))
    }
}

@Test("fork lineage metadata is structured and durable")
func testFork_LineageMetadataStructuredAndPersisted() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(
            context: (),
            nowNanoseconds: 42,
            checkpointStore: AnyHiveCheckpointStore(store)
        )
    )

    let sourceThreadID = HiveThreadID("source-lineage")
    let targetThreadID = HiveThreadID("target-lineage")
    let sourceCheckpointID = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    let result = try await runtime.fork(
        threadID: sourceThreadID,
        to: targetThreadID,
        from: sourceCheckpointID,
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    guard let lineage = result.lineage else {
        Issue.record("Expected lineage metadata")
        return
    }

    #expect(lineage.sourceThreadID == sourceThreadID)
    #expect(lineage.sourceCheckpointID == sourceCheckpointID)
    #expect(lineage.targetThreadID == targetThreadID)
    #expect(lineage.targetRunID == result.runID)
    #expect(lineage.createdAtNanoseconds == 42)

    guard let targetCheckpointID = result.targetCheckpointID else {
        Issue.record("Expected persisted target checkpoint")
        return
    }

    let persisted = try await runtime.getCheckpoint(threadID: targetThreadID, id: targetCheckpointID)
    #expect(persisted?.lineage?.lineageID == lineage.lineageID)
}

@Test("fork emits started completed and failed events with deterministic ordering")
func testFork_EmitsLifecycleEvents() async throws {
    let store = ForkQueryableStore<ForkBaseSchema>()
    let graph = try makeForkGraph()
    let runtime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let sourceThreadID = HiveThreadID("source-events")
    _ = try await seedCheckpointForSource(runtime: runtime, sourceThreadID: sourceThreadID)

    _ = try await runtime.fork(threadID: sourceThreadID, to: HiveThreadID("target-events-ok"))

    do {
        _ = try await runtime.fork(threadID: HiveThreadID("missing-source"), to: HiveThreadID("target-events-fail"))
        Issue.record("Expected fork failure")
    } catch {}

    let forkEvents = await runtime.getForkEventHistory()
    #expect(forkEvents.count >= 4)

    let started = forkEvents.filter {
        if case .forkStarted = $0.kind { return true }
        return false
    }
    let completed = forkEvents.filter {
        if case .forkCompleted = $0.kind { return true }
        return false
    }
    let failed = forkEvents.filter {
        if case .forkFailed = $0.kind { return true }
        return false
    }

    #expect(!started.isEmpty)
    #expect(!completed.isEmpty)
    #expect(!failed.isEmpty)

    if let firstStarted = started.first, let firstCompleted = completed.first {
        #expect(firstStarted.id.eventIndex < firstCompleted.id.eventIndex)
    }
}

@Test("fork determinism: repeated forks produce identical transcript and final state hashes")
func testFork_DeterminismRepeatedRuns() async throws {
    let iterations = 3

    let graph = try makeForkGraph()
    let sourceThreadID = HiveThreadID("source-det")
    let targetThreadID = HiveThreadID("target-det")

    let baselineStore = ForkQueryableStore<ForkBaseSchema>()
    let baselineRuntime = try HiveRuntime(
        graph: graph,
        environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(baselineStore))
    )
    let sourceCheckpointID = try await seedCheckpointForSource(
        runtime: baselineRuntime,
        sourceThreadID: sourceThreadID
    )
    guard let baselineCheckpoint = try await baselineRuntime.getCheckpoint(
        threadID: sourceThreadID,
        id: sourceCheckpointID
    ) else {
        Issue.record("Expected baseline checkpoint")
        return
    }

    var transcriptHashes: [String] = []
    var finalStateHashes: [String] = []

    for _ in 0..<iterations {
        let store = ForkQueryableStore<ForkBaseSchema>()
        await store.seed(baselineCheckpoint)
        let runtime = try HiveRuntime(
            graph: graph,
            environment: makeForkEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
        )

        _ = try await runtime.fork(
            threadID: sourceThreadID,
            to: targetThreadID,
            from: sourceCheckpointID,
            options: HiveRunOptions(checkpointPolicy: .everyStep)
        )

        let runTarget = await runtime.run(
            threadID: targetThreadID,
            input: 0,
            options: HiveRunOptions(checkpointPolicy: .everyStep)
        )
        _ = try await runTarget.outcome.value
        _ = await drainEvents(runTarget.events)

        let forkEvents = await runtime.getForkEventHistory()
        let transcriptHash = sha256Hex(stableEventBytes(forkEvents))
        transcriptHashes.append(transcriptHash)

        let state = try await runtime.getState(threadID: targetThreadID)
        let value = try state?.store.get(ForkBaseSchema.Channels.value) ?? -1
        let notes = try state?.store.get(ForkBaseSchema.Channels.notes) ?? []
        let statePayload = "value=\(value)|notes=\(notes.joined(separator: ","))"
        finalStateHashes.append(sha256Hex(Data(statePayload.utf8)))
    }

    #expect(Set(transcriptHashes).count == 1)
    #expect(Set(finalStateHashes).count == 1)
}
