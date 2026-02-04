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

private func taskStartsByStep(_ events: [HiveEvent]) -> [Int: [HiveNodeID]] {
    var result: [Int: [HiveNodeID]] = [:]
    for event in events {
        guard let stepIndex = event.id.stepIndex else { continue }
        guard case let .taskStarted(nodeID, _) = event.kind else { continue }
        result[stepIndex, default: []].append(nodeID)
    }
    return result
}

private func channelVersionsByChannelID<Schema: HiveSchema>(_ checkpoint: HiveCheckpoint<Schema>) -> [String: UInt64]? {
    Mirror(reflecting: checkpoint).descendant("channelVersionsByChannelID") as? [String: UInt64]
}

private func versionsSeenByNodeID<Schema: HiveSchema>(_ checkpoint: HiveCheckpoint<Schema>) -> [String: [String: UInt64]]? {
    Mirror(reflecting: checkpoint).descendant("versionsSeenByNodeID") as? [String: [String: UInt64]]
}

private func checkpointFormatVersion<Schema: HiveSchema>(_ checkpoint: HiveCheckpoint<Schema>) -> String? {
    Mirror(reflecting: checkpoint).descendant("checkpointFormatVersion") as? String
}

private enum TestRunWhen: Sendable {
    case always
    case anyOf([HiveChannelID])
    case allOf([HiveChannelID])
}

private extension HiveGraphBuilder {
    mutating func addNodeV11(
        _ id: HiveNodeID,
        runWhen: TestRunWhen,
        retryPolicy: HiveRetryPolicy = .none,
        _ node: @escaping HiveNode<Schema>
    ) {
#if HIVE_V11_TRIGGERS
        let mapped: HiveNodeRunWhen = switch runWhen {
        case .always:
            .always
        case .anyOf(let channels):
            .anyOf(channels: channels)
        case .allOf(let channels):
            .allOf(channels: channels)
        }
        self.addNode(id, retryPolicy: retryPolicy, runWhen: mapped, node)
#else
        self.addNode(id, retryPolicy: retryPolicy, node)
#endif
    }
}

@Test("Channel versions increment once per committed step per written global channel")
func testChannelVersions_IncrementOncePerCommittedStepPerWrittenChannel() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))
            return [
                AnyHiveChannelSpec(
                    HiveChannelSpec(
                        key: aKey,
                        scope: .global,
                        reducer: HiveReducer { current, update in current + update },
                        updatePolicy: .multi,
                        initial: { 0 },
                        persistence: .untracked
                    )
                ),
                AnyHiveChannelSpec(
                    HiveChannelSpec(
                        key: bKey,
                        scope: .global,
                        reducer: HiveReducer { current, update in current + update },
                        updatePolicy: .multi,
                        initial: { 0 },
                        persistence: .untracked
                    )
                ),
            ]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
    let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))

    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("C")]))
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1), AnyHiveWrite(bKey, 1)], next: .nodes([HiveNodeID("C")]))
    }
    builder.addNode(HiveNodeID("C")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("D")]))
    }
    builder.addNode(HiveNodeID("D")) { _ in
        HiveNodeOutput(next: .end) // no writes in this step
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("channel-versions"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    _ = try await handle.outcome.value

    let checkpoints = await store.all().sorted { $0.stepIndex < $1.stepIndex }
    #expect(checkpoints.map(\.stepIndex) == [1, 2, 3])

    guard let v1 = channelVersionsByChannelID(checkpoints[0]) else { #expect(Bool(false)); return }
    guard let v2 = channelVersionsByChannelID(checkpoints[1]) else { #expect(Bool(false)); return }
    guard let v3 = channelVersionsByChannelID(checkpoints[2]) else { #expect(Bool(false)); return }

    #expect(v1["a"] == 1)
    #expect(v1["b"] == 1)

    #expect(v2["a"] == 2)
    #expect(v2["b"] == 1)

    // Step 2 (node D) commits with no writes: versions must not advance.
    #expect(v3["a"] == 2)
    #expect(v3["b"] == 1)
}

@Test("versionsSeen snapshots at step start (pre-commit)")
func testVersionsSeen_SnapshotsAtStepStart_PreCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let spec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
    let store = TestCheckpointStore<Schema>()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("X")]))
    }
    builder.addNodeV11(HiveNodeID("X"), runWhen: .anyOf([HiveChannelID("a")])) { _ in
        // If versionsSeen is captured post-commit, it would see "a" at 2 after this write.
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(
        graph: graph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )

    let handle = await runtime.run(
        threadID: HiveThreadID("versions-seen-timing"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )

    _ = try await handle.outcome.value

    let checkpoints = await store.all().sorted { $0.stepIndex < $1.stepIndex }
    #expect(checkpoints.map(\.stepIndex) == [1, 2])

    guard let seen = versionsSeenByNodeID(checkpoints[1]) else { #expect(Bool(false)); return }
    guard let xSeen = seen["X"] else { #expect(Bool(false)); return }
    #expect(xSeen["a"] == 1)
}

@Test("runWhen anyOf filters scheduling when no channels changed")
func testRunWhenAnyOf_FiltersScheduling_WhenNoChannelsChanged() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let spec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))

    final class Counter: @unchecked Sendable {
        var count: Int = 0
    }
    let counter = Counter()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        counter.count += 1
        if counter.count == 1 {
            return HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("B")]))
        }
        return HiveNodeOutput(next: .nodes([HiveNodeID("B")]))
    }
    builder.addNodeV11(HiveNodeID("B"), runWhen: .anyOf([HiveChannelID("a")])) { _ in
        HiveNodeOutput(next: .nodes([HiveNodeID("A")]))
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("runwhen-anyof"),
        input: (),
        options: HiveRunOptions(maxSteps: 4, checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    // Expected with triggers: A (writes), B (initial run), A (no write) then frontier becomes empty (B filtered out).
    // Without triggers, this graph never quiesces and hits maxSteps.
    guard case .finished = outcome else {
        #expect(Bool(false))
        return
    }

    let starts = taskStartsByStep(events)
    #expect(starts[0] == [HiveNodeID("A")])
    #expect(starts[1] == [HiveNodeID("B")])
    #expect(starts[2] == [HiveNodeID("A")])
    #expect(starts[3] == nil)
}

@Test("Input writes bump channel versions and can re-trigger nodes across runs")
func testInputWrites_BumpChannelVersions_CanRetriggerAcrossRuns() async throws {
    enum Schema: HiveSchema {
        typealias Input = Int

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let spec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }

        static func inputWrites(_ input: Int, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            return [AnyHiveWrite(aKey, input)]
        }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .nodes([HiveNodeID("X")]))
    }
    builder.addNodeV11(HiveNodeID("X"), runWhen: .anyOf([HiveChannelID("a")])) { _ in
        HiveNodeOutput(next: .end)
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))
    let threadID = HiveThreadID("input-writes-retrigger")

    let first = await runtime.run(threadID: threadID, input: 1, options: HiveRunOptions())
    let firstEventsTask = Task { await collectEvents(first.events) }
    _ = try await first.outcome.value
    let firstEvents = await firstEventsTask.value
    let firstStarted: [HiveNodeID] = firstEvents.compactMap { event in
        guard case let .taskStarted(node: nodeID, taskID: _) = event.kind else { return nil }
        return nodeID
    }
    #expect(firstStarted == [HiveNodeID("A"), HiveNodeID("X")])

    let second = await runtime.run(threadID: threadID, input: 5, options: HiveRunOptions())
    let secondEventsTask = Task { await collectEvents(second.events) }
    _ = try await second.outcome.value
    let secondEvents = await secondEventsTask.value
    let secondStarted: [HiveNodeID] = secondEvents.compactMap { event in
        guard case let .taskStarted(node: nodeID, taskID: _) = event.kind else { return nil }
        return nodeID
    }
    #expect(secondStarted == [HiveNodeID("A"), HiveNodeID("X")])
}

@Test("runWhen allOf requires all channels changed since last run")
func testRunWhenAllOf_RequiresAllChannelsChanged() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))
            return [
                AnyHiveChannelSpec(
                    HiveChannelSpec(
                        key: aKey,
                        scope: .global,
                        reducer: HiveReducer { current, update in current + update },
                        updatePolicy: .multi,
                        initial: { 0 },
                        persistence: .untracked
                    )
                ),
                AnyHiveChannelSpec(
                    HiveChannelSpec(
                        key: bKey,
                        scope: .global,
                        reducer: HiveReducer { current, update in current + update },
                        updatePolicy: .multi,
                        initial: { 0 },
                        persistence: .untracked
                    )
                ),
            ]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))

    final class Counter: @unchecked Sendable {
        var count: Int = 0
    }
    let counter = Counter()

    // Cycle: A -> C -> A.
    // A writes only channel "a" once. C has runWhen allOf([a,b]) so after its initial run it must be filtered
    // because "b" never changes.
    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        counter.count += 1
        if counter.count == 1 {
            return HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("C")]))
        }
        return HiveNodeOutput(next: .nodes([HiveNodeID("C")]))
    }
    builder.addNodeV11(HiveNodeID("C"), runWhen: .allOf([HiveChannelID("a"), HiveChannelID("b")])) { _ in
        HiveNodeOutput(next: .nodes([HiveNodeID("A")]))
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("runwhen-allof"),
        input: (),
        options: HiveRunOptions(maxSteps: 4, checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    let outcome = try await handle.outcome.value
    let events = await eventsTask.value

    // Expected with triggers:
    // - C runs once (missing seen => "changed" for both a,b).
    // - After that, C must never be scheduled again because "b" never changes.
    guard case .finished = outcome else {
        #expect(Bool(false))
        return
    }

    let starts = taskStartsByStep(events)
    #expect(starts[0] == [HiveNodeID("A")])
    #expect(starts[1] == [HiveNodeID("C")])
    #expect(starts[2] == [HiveNodeID("A")])
    #expect(starts[3] == nil)
}

@Test("Join-edge seeds bypass triggers when join becomes available")
func testJoinSeeds_BypassTriggerFiltering() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let spec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("J")])
    builder.addNodeV11(HiveNodeID("J"), runWhen: .anyOf([HiveChannelID("a")])) { _ in
        HiveNodeOutput(next: .end)
    }
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .nodes([HiveNodeID("B")]))
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("J"))

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("join-bypass"),
        input: (),
        options: HiveRunOptions(maxSteps: 10, checkpointPolicy: .disabled)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let starts = taskStartsByStep(events)
    #expect(starts[0] == [HiveNodeID("A"), HiveNodeID("J")])
    #expect(starts[1] == [HiveNodeID("B")])
    #expect(starts[2] == [HiveNodeID("J")])
}

@Test("Checkpoint migration defaults missing v1.1 fields deterministically")
func testCheckpointMigration_DefaultsForMissingV11Fields() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let json = """
    {
      "id": { "rawValue": "cp-old" },
      "threadID": { "rawValue": "t-old" },
      "runID": { "rawValue": "00000000-0000-0000-0000-000000000000" },
      "stepIndex": 0,
      "schemaVersion": "schema",
      "graphVersion": "graph",
      "globalDataByChannelID": {},
      "frontier": [],
      "joinBarrierSeenByJoinID": {},
      "interruption": null
    }
    """

    let decoded = try JSONDecoder().decode(HiveCheckpoint<Schema>.self, from: Data(json.utf8))

    guard let format = checkpointFormatVersion(decoded) else { #expect(Bool(false)); return }
    #expect(format == "HCP1")

    guard let versions = channelVersionsByChannelID(decoded) else { #expect(Bool(false)); return }
    #expect(versions.isEmpty)

    guard let seen = versionsSeenByNodeID(decoded) else { #expect(Bool(false)); return }
    #expect(seen.isEmpty)
}

@Test("Checkpoint + resume parity for trigger-enabled graph matches uninterrupted scheduling")
func testCheckpointResumeParity_TriggerEnabledGraph_MatchesUninterrupted() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
            let spec = HiveChannelSpec(
                key: aKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))

    final class Counter: @unchecked Sendable {
        var count: Int = 0
    }
    let counter = Counter()

    func makeGraph() throws -> CompiledHiveGraph<Schema> {
        var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
        builder.addNode(HiveNodeID("A")) { _ in
            counter.count += 1
            if counter.count == 1 {
                return HiveNodeOutput(writes: [AnyHiveWrite(aKey, 1)], next: .nodes([HiveNodeID("B")]))
            }
            return HiveNodeOutput(next: .nodes([HiveNodeID("B")]))
        }
        builder.addNodeV11(HiveNodeID("B"), runWhen: .anyOf([HiveChannelID("a")])) { _ in
            HiveNodeOutput(next: .nodes([HiveNodeID("A")]))
        }
        return try builder.compile()
    }

    // Baseline: triggers should quiesce before maxSteps.
    counter.count = 0
    let baselineGraph = try makeGraph()
    let baselineRuntime = HiveRuntime(graph: baselineGraph, environment: makeEnvironment(context: ()))
    let baselineHandle = await baselineRuntime.run(
        threadID: HiveThreadID("parity-baseline"),
        input: (),
        options: HiveRunOptions(maxSteps: 6, checkpointPolicy: .disabled)
    )
    let baselineEventsTask = Task { await collectEvents(baselineHandle.events) }
    let baselineOutcome = try await baselineHandle.outcome.value
    let baselineEvents = await baselineEventsTask.value

    guard case .finished = baselineOutcome else { #expect(Bool(false)); return }

    // Checkpointed + resume: stop after step 1, then resume and expect identical task-start schedule overall.
    counter.count = 0
    let checkpointGraph = try makeGraph()
    let store = TestCheckpointStore<Schema>()

    let checkpointedRuntime = HiveRuntime(
        graph: checkpointGraph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let first = await checkpointedRuntime.run(
        threadID: HiveThreadID("parity"),
        input: (),
        options: HiveRunOptions(maxSteps: 2, checkpointPolicy: .everyStep)
    )
    let firstEventsTask = Task { await collectEvents(first.events) }
    let firstOutcome = try await first.outcome.value
    let firstEvents = await firstEventsTask.value
    guard case .outOfSteps = firstOutcome else { #expect(Bool(false)); return }

    let resumedRuntime = HiveRuntime(
        graph: checkpointGraph,
        environment: makeEnvironment(context: (), checkpointStore: AnyHiveCheckpointStore(store))
    )
    let resumed = await resumedRuntime.run(
        threadID: HiveThreadID("parity"),
        input: (),
        options: HiveRunOptions(maxSteps: 6, checkpointPolicy: .everyStep)
    )
    let resumedEventsTask = Task { await collectEvents(resumed.events) }
    let resumedOutcome = try await resumed.outcome.value
    let resumedEvents = await resumedEventsTask.value
    guard case .finished = resumedOutcome else { #expect(Bool(false)); return }

    let baselineStarts = taskStartsByStep(baselineEvents)
    var stitchedStarts = taskStartsByStep(firstEvents)
    for (step, nodes) in taskStartsByStep(resumedEvents) {
        stitchedStarts[step] = nodes
    }
    #expect(stitchedStarts == baselineStarts)
}
