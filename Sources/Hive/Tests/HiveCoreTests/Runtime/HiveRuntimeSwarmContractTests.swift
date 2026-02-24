import Foundation
import Testing
@testable import HiveCore

private struct SwarmNoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct SwarmNoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor SwarmCheckpointStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {
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
        let summaries = checkpoints
            .filter { $0.threadID == threadID }
            .sorted { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.stepIndex > rhs.stepIndex
            }
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
        guard let limit else { return summaries }
        return Array(summaries.prefix(max(0, limit)))
    }

    func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints.first { $0.threadID == threadID && $0.id == id }
    }
}

private func makeSwarmEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: SwarmNoopClock(),
        logger: SwarmNoopLogger(),
        checkpointStore: checkpointStore
    )
}

private func collectSwarmEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
    } catch {
        return events
    }
    return events
}

private func collectSwarmEventsAndError(
    _ stream: AsyncThrowingStream<HiveEvent, Error>
) async -> ([HiveEvent], Error?) {
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

@Test("getState returns deterministic typed runtime snapshot")
func getStateReturnsDeterministicTypedSnapshot() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: valueKey,
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

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(valueKey, 7)],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))

    let threadID = HiveThreadID("state-snapshot")
    let handle = await runtime.run(
        threadID: threadID,
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .disabled)
    )
    _ = try await handle.outcome.value
    _ = await collectSwarmEvents(handle.events)

    let first = try #require(try await runtime.getState(threadID: threadID))
    let second = try #require(try await runtime.getState(threadID: threadID))

    #expect(first.threadID == threadID)
    #expect(first.runID == handle.runID)
    #expect(first.stepIndex == 1)
    #expect(first.interruption == nil)
    #expect(first.nextNodes == [HiveNodeID("B")])
    #expect(try first.store.get(valueKey) == 7)
    #expect((first.globalChannelPayloadHashesByID[HiveChannelID("value")] ?? "").count == 64)
    #expect(first.deterministicRepresentationHash == second.deterministicRepresentationHash)
}

@Test("getState returns nil for missing thread")
func getStateMissingThreadReturnsNil() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    let snapshot = try await runtime.getState(threadID: HiveThreadID("never-started"))
    #expect(snapshot == nil)
}

@Test("checkpoint capability discovery reports queryable and non-queryable stores")
func checkpointCapabilityDiscoveryReportsSupport() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtimeWithoutStore = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    #expect(await runtimeWithoutStore.checkpointCapabilities() == .none)

    let queryableStore = SwarmCheckpointStore<Schema>()
    let runtimeWithStore = try HiveRuntime(
        graph: graph,
        environment: makeSwarmEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(queryableStore))
    )
    #expect(await runtimeWithStore.checkpointCapabilities() == .queryable)
}

@Test("validateRunOptions reports typed fail-fast errors")
func validateRunOptionsReportsTypedFailFastErrors() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))

    do {
        try await runtime.validateRunOptions(HiveRunOptions(maxSteps: -1))
        #expect(Bool(false))
    } catch let error as HiveRunOptionsValidationError {
        guard case .invalidBounds(let option, _) = error else {
            #expect(Bool(false))
            return
        }
        #expect(option == "maxSteps")
    }

    do {
        try await runtime.validateRunOptions(HiveRunOptions(checkpointPolicy: .everyStep))
        #expect(Bool(false))
    } catch let error as HiveRunOptionsValidationError {
        guard case .missingRequiredComponent(let component, _) = error else {
            #expect(Bool(false))
            return
        }
        #expect(component == "checkpointStore")
    }

    do {
        try await runtime.validateRunOptions(
            HiveRunOptions(deterministicTokenStreaming: true, streamingMode: .combined)
        )
        #expect(Bool(false))
    } catch let error as HiveRunOptionsValidationError {
        guard case .unsupportedCombination = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test("run uses shared preflight validation fail-fast")
func runUsesSharedPreflightValidationFailFast() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    let handle = await runtime.run(
        threadID: HiveThreadID("preflight-failfast"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    let eventsTask = Task { await collectSwarmEventsAndError(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRunOptionsValidationError {
        guard case .missingRequiredComponent(let component, _) = error else {
            #expect(Bool(false))
            return
        }
        #expect(component == "checkpointStore")
    }

    let (events, streamError) = await eventsTask.value
    #expect(events.isEmpty)
    #expect(streamError is HiveRunOptionsValidationError)
}

@Test("events carry stable schema version markers")
func eventsCarryStableSchemaVersionMarkers() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    let handle = await runtime.run(
        threadID: HiveThreadID("event-schema-version"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectSwarmEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    #expect(events.isEmpty == false)
    #expect(events.allSatisfy { $0.schemaVersion == .current })
}

@Test("transcript hashing is deterministic across identical runs")
func transcriptHashingIsDeterministicAcrossRuns() async throws {
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

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 1)], next: .end)
    }
    let graph = try builder.compile()

    let runtime1 = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    let run1 = await runtime1.run(threadID: HiveThreadID("deterministic"), input: (), options: HiveRunOptions())
    let run1EventsTask = Task { await collectSwarmEvents(run1.events) }
    _ = try await run1.outcome.value
    let run1Events = await run1EventsTask.value
    let state1 = try #require(try await runtime1.getState(threadID: HiveThreadID("deterministic")))

    let runtime2 = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))
    let run2 = await runtime2.run(threadID: HiveThreadID("deterministic"), input: (), options: HiveRunOptions())
    let run2EventsTask = Task { await collectSwarmEvents(run2.events) }
    _ = try await run2.outcome.value
    let run2Events = await run2EventsTask.value
    let state2 = try #require(try await runtime2.getState(threadID: HiveThreadID("deterministic")))

    let transcript1 = HiveEventTranscript(events: run1Events)
    let transcript2 = HiveEventTranscript(events: run2Events)

    #expect(try transcript1.transcriptHash() == transcript2.transcriptHash())
    #expect(HiveTranscriptHasher.finalStateHash(stateSnapshot: state1) == HiveTranscriptHasher.finalStateHash(stateSnapshot: state2))

    let diff = transcript1.firstDiff(comparedTo: transcript2)
    #expect(diff == nil)
}

@Test("transcript diff reports first divergent key path")
func transcriptDiffReportsFirstDivergentKeyPath() async throws {
    let base = HiveEventTranscript(
        schemaVersion: .current,
        events: [
            HiveTranscriptEvent(
                id: HiveTranscriptEventID(runID: "r", attemptID: "a", eventIndex: 0, stepIndex: nil, taskOrdinal: nil),
                kind: "run.started",
                fields: ["threadID": "t"],
                metadata: [:]
            )
        ]
    )

    let mutated = HiveEventTranscript(
        schemaVersion: .current,
        events: [
            HiveTranscriptEvent(
                id: HiveTranscriptEventID(runID: "r", attemptID: "a", eventIndex: 0, stepIndex: nil, taskOrdinal: nil),
                kind: "run.started",
                fields: ["threadID": "different"],
                metadata: [:]
            )
        ]
    )

    let diff = base.firstDiff(comparedTo: mutated)
    #expect(diff?.eventIndex == 0)
    #expect(diff?.keyPath == "events[0].fields.threadID")
}

@Test("replay compatibility validator fails typed on schema mismatch")
func replayCompatibilityValidatorFailsTypedOnSchemaMismatch() throws {
    let transcript = HiveEventTranscript(schemaVersion: .v0, events: [])
    do {
        try transcript.validateReplayCompatibility(expected: .current)
        #expect(Bool(false))
    } catch let error as HiveEventReplayCompatibilityError {
        guard case .incompatibleSchemaVersion(let expected, let found) = error else {
            #expect(Bool(false))
            return
        }
        #expect(expected == .current)
        #expect(found == .v0)
    }
}

@Test("external writes reject invalid batches atomically")
func externalWritesRejectInvalidBatchesAtomically() async throws {
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

    let validKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let invalidKey = HiveChannelKey<Schema, Int>(HiveChannelID("unknown"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()

    let runtime = try HiveRuntime(graph: graph, environment: makeSwarmEnvironment(context: ()))

    // Seed thread state.
    let seed = await runtime.run(threadID: HiveThreadID("ext-atomic"), input: (), options: HiveRunOptions())
    _ = try await seed.outcome.value
    _ = await collectSwarmEvents(seed.events)

    let handle = await runtime.applyExternalWrites(
        threadID: HiveThreadID("ext-atomic"),
        writes: [
            AnyHiveWrite(validKey, 10),
            AnyHiveWrite(invalidKey, 99)
        ],
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectSwarmEvents(handle.events) }
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveExternalWriteError {
        guard case .unknownChannel(let channelID) = error else {
            #expect(Bool(false))
            return
        }
        #expect(channelID == HiveChannelID("unknown"))
    }

    let events = await eventsTask.value
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)

    let state = try #require(try await runtime.getState(threadID: HiveThreadID("ext-atomic")))
    #expect(try state.store.get(validKey) == 0)
}
