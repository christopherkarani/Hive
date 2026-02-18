import CryptoKit
import Foundation
import Testing
@testable import HiveCore

private struct TestClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct TestLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private func makeEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: TestClock(),
        logger: TestLogger(),
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
    func encode(_ value: Int) throws -> Data { Data(String(value).utf8) }
    func decode(_ data: Data) throws -> Int {
        guard let v = Int(String(decoding: data, as: UTF8.self)) else {
            throw CocoaError(.coderValueNotFound)
        }
        return v
    }
}

private actor TestCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    var checkpoints: [HiveCheckpoint<Schema>] = []

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

// MARK: - Streaming Mode Tests

@Suite("HiveRuntimeStreamingModes")
struct HiveRuntimeStreamingModeTests {

    // MARK: - Shared Schema

    /// Simple two-node A → B schema with one global "messages" channel.
    private enum TwoNodeSchema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<TwoNodeSchema>] {
            let key = HiveChannelKey<TwoNodeSchema, Int>(HiveChannelID("messages"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    private static let messagesKey = HiveChannelKey<TwoNodeSchema, Int>(HiveChannelID("messages"))

    private static func buildTwoNodeGraph() throws -> CompiledHiveGraph<TwoNodeSchema> {
        var builder = HiveGraphBuilder<TwoNodeSchema>(start: [HiveNodeID("A")])
        builder.addNode(HiveNodeID("A")) { _ in
            HiveNodeOutput(
                writes: [AnyHiveWrite(messagesKey, 10)],
                next: .nodes([HiveNodeID("B")])
            )
        }
        builder.addNode(HiveNodeID("B")) { _ in
            HiveNodeOutput(
                writes: [AnyHiveWrite(messagesKey, 5)],
                next: .end
            )
        }
        builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
        return try builder.compile()
    }

    // MARK: - Tests

    @Test("Default .events mode emits no streaming events")
    func defaultEventsModeNoStreamingEvents() async throws {
        let graph = try Self.buildTwoNodeGraph()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(streamingMode: .events)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        // No storeSnapshot or channelUpdates events should be present.
        let snapshotEvents = events.filter {
            if case .storeSnapshot = $0.kind { return true }
            return false
        }
        let updateEvents = events.filter {
            if case .channelUpdates = $0.kind { return true }
            return false
        }

        #expect(snapshotEvents.isEmpty)
        #expect(updateEvents.isEmpty)
    }

    @Test(".values mode emits storeSnapshot after each step")
    func valuesModeEmitsStoreSnapshot() async throws {
        let graph = try Self.buildTwoNodeGraph()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(streamingMode: .values)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        // Should have storeSnapshot events — one per step (2 steps: A, then B).
        let snapshotEvents = events.filter {
            if case .storeSnapshot = $0.kind { return true }
            return false
        }
        #expect(snapshotEvents.count == 2)

        // Each snapshot should contain the "messages" channel.
        for event in snapshotEvents {
            guard case let .storeSnapshot(channelValues) = event.kind else {
                #expect(Bool(false), "Expected storeSnapshot kind")
                return
            }
            let channelIDs = channelValues.map(\.channelID)
            #expect(channelIDs.contains(HiveChannelID("messages")))
            // Verify hash is 64 hex chars (SHA-256).
            for cv in channelValues {
                #expect(cv.payloadHash.count == 64)
            }
        }

        // No channelUpdates events.
        let updateEvents = events.filter {
            if case .channelUpdates = $0.kind { return true }
            return false
        }
        #expect(updateEvents.isEmpty)
    }

    @Test(".updates mode emits channelUpdates with only written channels")
    func updatesModeEmitsChannelUpdates() async throws {
        let graph = try Self.buildTwoNodeGraph()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(streamingMode: .updates)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        // Should have channelUpdates events.
        let updateEvents = events.filter {
            if case .channelUpdates = $0.kind { return true }
            return false
        }
        #expect(updateEvents.count == 2)

        // Each update should only contain channels written in that step.
        for event in updateEvents {
            guard case let .channelUpdates(channelValues) = event.kind else {
                #expect(Bool(false), "Expected channelUpdates kind")
                return
            }
            // Both steps write to "messages" only.
            let channelIDs = channelValues.map(\.channelID)
            #expect(channelIDs == [HiveChannelID("messages")])
        }

        // No storeSnapshot events.
        let snapshotEvents = events.filter {
            if case .storeSnapshot = $0.kind { return true }
            return false
        }
        #expect(snapshotEvents.isEmpty)
    }

    @Test(".combined mode emits both storeSnapshot and channelUpdates")
    func combinedModeEmitsBoth() async throws {
        let graph = try Self.buildTwoNodeGraph()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(streamingMode: .combined)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        let snapshotEvents = events.filter {
            if case .storeSnapshot = $0.kind { return true }
            return false
        }
        let updateEvents = events.filter {
            if case .channelUpdates = $0.kind { return true }
            return false
        }

        #expect(snapshotEvents.count == 2)
        #expect(updateEvents.count == 2)

        // storeSnapshot should come before channelUpdates for each step.
        // Verify by checking event indices — within each step, snapshot precedes updates.
        let kinds = events.map(\.kind)
        for i in 0..<kinds.count {
            if case .storeSnapshot = kinds[i] {
                // The next streaming event should be channelUpdates.
                if i + 1 < kinds.count {
                    if case .channelUpdates = kinds[i + 1] {
                        // Expected ordering preserved.
                    } else {
                        #expect(Bool(false), "Expected channelUpdates immediately after storeSnapshot")
                    }
                }
            }
        }
    }

    @Test("Streaming events appear between checkpoint and stepFinished")
    func streamingEventsBetweenCheckpointAndStepFinished() async throws {
        // Schema with a checkpointed channel (requires codec).
        enum CheckpointSchema: HiveSchema {
            static var channelSpecs: [AnyHiveChannelSpec<CheckpointSchema>] {
                let key = HiveChannelKey<CheckpointSchema, Int>(HiveChannelID("counter"))
                let codec = IntCodec(id: "int-codec")
                let spec = HiveChannelSpec(
                    key: key,
                    scope: .global,
                    reducer: HiveReducer { current, update in current + update },
                    updatePolicy: .multi,
                    initial: { 0 },
                    codec: HiveAnyCodec(codec),
                    persistence: .checkpointed
                )
                return [AnyHiveChannelSpec(spec)]
            }
        }

        let counterKey = HiveChannelKey<CheckpointSchema, Int>(HiveChannelID("counter"))
        let store = TestCheckpointStore<CheckpointSchema>()

        var builder = HiveGraphBuilder<CheckpointSchema>(start: [HiveNodeID("A")])
        builder.addNode(HiveNodeID("A")) { _ in
            HiveNodeOutput(
                writes: [AnyHiveWrite(counterKey, 1)],
                next: .end
            )
        }

        let graph = try builder.compile()
        let runtime = try HiveRuntime(
            graph: graph,
            environment: makeEnvironment(
                context: (),
                checkpointStore: AnyHiveCheckpointStore(store)
            )
        )

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(
                checkpointPolicy: .everyStep,
                streamingMode: .values
            )
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        let kinds = events.map(\.kind)

        // Find indices of key events.
        var checkpointSavedIndex: Int?
        var storeSnapshotIndex: Int?
        var stepFinishedIndex: Int?

        for (i, kind) in kinds.enumerated() {
            switch kind {
            case .checkpointSaved:
                checkpointSavedIndex = i
            case .storeSnapshot:
                storeSnapshotIndex = i
            case .stepFinished:
                stepFinishedIndex = i
            default:
                break
            }
        }

        // Verify ordering: checkpointSaved < storeSnapshot < stepFinished.
        if let cpIdx = checkpointSavedIndex, let snapIdx = storeSnapshotIndex, let sfIdx = stepFinishedIndex {
            #expect(cpIdx < snapIdx, "storeSnapshot must come after checkpointSaved")
            #expect(snapIdx < sfIdx, "storeSnapshot must come before stepFinished")
        } else {
            #expect(checkpointSavedIndex != nil, "Expected checkpointSaved event")
            #expect(storeSnapshotIndex != nil, "Expected storeSnapshot event")
            #expect(stepFinishedIndex != nil, "Expected stepFinished event")
        }
    }

    @Test("Multi-channel schema snapshot contains all global channels")
    func multiChannelSnapshotContainsAllGlobalChannels() async throws {
        enum MultiSchema: HiveSchema {
            static var channelSpecs: [AnyHiveChannelSpec<MultiSchema>] {
                let aKey = HiveChannelKey<MultiSchema, Int>(HiveChannelID("alpha"))
                let bKey = HiveChannelKey<MultiSchema, Int>(HiveChannelID("beta"))
                let specA = HiveChannelSpec(
                    key: aKey,
                    scope: .global,
                    reducer: HiveReducer.lastWriteWins(),
                    updatePolicy: .multi,
                    initial: { 0 },
                    persistence: .untracked
                )
                let specB = HiveChannelSpec(
                    key: bKey,
                    scope: .global,
                    reducer: HiveReducer.lastWriteWins(),
                    updatePolicy: .multi,
                    initial: { 0 },
                    persistence: .untracked
                )
                return [AnyHiveChannelSpec(specA), AnyHiveChannelSpec(specB)]
            }
        }

        let aKey = HiveChannelKey<MultiSchema, Int>(HiveChannelID("alpha"))

        var builder = HiveGraphBuilder<MultiSchema>(start: [HiveNodeID("A")])
        // Node A writes only to "alpha".
        builder.addNode(HiveNodeID("A")) { _ in
            HiveNodeOutput(
                writes: [AnyHiveWrite(aKey, 42)],
                next: .end
            )
        }

        let graph = try builder.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID("t1"),
            input: (),
            options: HiveRunOptions(streamingMode: .combined)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        // storeSnapshot should contain BOTH alpha and beta (all global channels).
        let snapshotEvents = events.compactMap { event -> [HiveSnapshotValue]? in
            guard case let .storeSnapshot(values) = event.kind else { return nil }
            return values
        }
        #expect(snapshotEvents.count == 1)
        let snapshotChannelIDs = Set(snapshotEvents[0].map(\.channelID))
        #expect(snapshotChannelIDs.contains(HiveChannelID("alpha")))
        #expect(snapshotChannelIDs.contains(HiveChannelID("beta")))

        // channelUpdates should contain ONLY alpha (the channel written to).
        let updateEvents = events.compactMap { event -> [HiveSnapshotValue]? in
            guard case let .channelUpdates(values) = event.kind else { return nil }
            return values
        }
        #expect(updateEvents.count == 1)
        let updateChannelIDs = updateEvents[0].map(\.channelID)
        #expect(updateChannelIDs == [HiveChannelID("alpha")])
    }
}
