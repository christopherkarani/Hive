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

private func makeEnvironment<Schema: HiveSchema>(context: Schema.Context) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: TestClock(),
        logger: TestLogger()
    )
}

private func collectEvents(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
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

@Test("Router fresh read sees own write only")
func testRouterFreshRead_SeesOwnWriteNotOthers() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
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

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(valueKey, 1)],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(valueKey, 1)],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("X")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("Y")) { _ in HiveNodeOutput(next: .end) }

    builder.addRouter(from: HiveNodeID("A")) { view in
        let value = (try? view.get(valueKey)) ?? 0
        return value == 1 ? .nodes([HiveNodeID("X")]) : .nodes([HiveNodeID("Y")])
    }
    builder.addRouter(from: HiveNodeID("B")) { view in
        let value = (try? view.get(valueKey)) ?? 0
        return value == 1 ? .nodes([HiveNodeID("Y")]) : .nodes([HiveNodeID("X")])
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t1"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }

    #expect(step1Tasks == [HiveNodeID("X"), HiveNodeID("Y")])
}

@Test("Router fresh read error aborts step")
func testRouterFreshRead_ErrorAbortsStep() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            final class ThrowOnce: @unchecked Sendable {
                var hasThrown = false
            }
            let state = ThrowOnce()
            let reducer = HiveReducer<Int> { current, update in
                if state.hasThrown {
                    throw HiveRuntimeError.invalidRunOptions("router view error")
                }
                state.hasThrown = true
                return current + update
            }
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: reducer,
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
            writes: [AnyHiveWrite(valueKey, 1)],
            next: .useGraphEdges
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addRouter(from: HiveNodeID("A")) { _ in .nodes([HiveNodeID("B")]) }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t2"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch {
        #expect(String(describing: error).contains("router view error"))
    }

    let events = await eventsTask.value
    let hasWriteApplied = events.contains { event in
        if case .writeApplied = event.kind { return true }
        return false
    }
    let hasStepFinished = events.contains { event in
        if case .stepFinished = event.kind { return true }
        return false
    }

    #expect(hasWriteApplied == false)
    #expect(hasStepFinished == false)
}

@Test("Router useGraphEdges falls back to static edges")
func testRouterReturnUseGraphEdges_FallsBackToStaticEdges() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .useGraphEdges) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("C")) { _ in HiveNodeOutput(next: .end) }

    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("C"))

    builder.addRouter(from: HiveNodeID("A")) { _ in .useGraphEdges }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t3"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }

    #expect(step1Tasks == [HiveNodeID("B"), HiveNodeID("C")])
}

@Test("Global write ordering deterministic under random completion")
func testGlobalWriteOrdering_DeterministicUnderRandomCompletion() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, [Int]>(HiveChannelID("values"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer.append(),
                updatePolicy: .multi,
                initial: { [] },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valuesKey = HiveChannelKey<Schema, [Int]>(HiveChannelID("values"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        try await Task.sleep(nanoseconds: 50_000_000)
        return HiveNodeOutput(writes: [
            AnyHiveWrite(valuesKey, [1]),
            AnyHiveWrite(valuesKey, [2])
        ])
    }
    builder.addNode(HiveNodeID("B")) { _ in
        try await Task.sleep(nanoseconds: 5_000_000)
        return HiveNodeOutput(writes: [AnyHiveWrite(valuesKey, [3])])
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t4"),
        input: (),
        options: HiveRunOptions()
    )

    let outcome = try await handle.outcome.value
    guard case let .finished(output, _) = outcome else {
        #expect(Bool(false))
        return
    }
    guard case let .fullStore(store) = output else {
        #expect(Bool(false))
        return
    }

    let values = try store.get(valuesKey)
    #expect(values == [1, 2, 3])
}

@Test("Dedupe applies to graph seeds only")
func testDedupe_GraphSeedsOnly() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            spawn: [
                HiveTaskSeed(nodeID: HiveNodeID("C")),
                HiveTaskSeed(nodeID: HiveNodeID("C"))
            ],
            next: .nodes([HiveNodeID("B"), HiveNodeID("B")])
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("C")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t5"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }

    #expect(step1Tasks == [HiveNodeID("B"), HiveNodeID("C"), HiveNodeID("C")])
}

@Test("Frontier ordering graph before spawn")
func testFrontierOrdering_GraphBeforeSpawn() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            spawn: [HiveTaskSeed(nodeID: HiveNodeID("C"))],
            next: .nodes([HiveNodeID("B")])
        )
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("C")) { _ in HiveNodeOutput(next: .end) }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t6"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }

    #expect(step1Tasks == [HiveNodeID("B"), HiveNodeID("C")])
}

@Test("Join barrier includes spawn parents")
func testJoinBarrier_IncludesSpawnParents() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("S")])
    builder.addNode(HiveNodeID("S")) { _ in
        HiveNodeOutput(
            spawn: [HiveTaskSeed(nodeID: HiveNodeID("B"))],
            next: .nodes([HiveNodeID("A")])
        )
    }
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("J")) { _ in HiveNodeOutput(next: .end) }
    builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("J"))

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t7"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step2Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 2 ? node : nil
    }

    #expect(step2Tasks == [HiveNodeID("J")])
}

@Test("Join target runs early does not reset")
func testJoinBarrier_TargetRunsEarly_DoesNotReset() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("S")])
    builder.addNode(HiveNodeID("S")) { _ in
        HiveNodeOutput(next: .nodes([HiveNodeID("J"), HiveNodeID("A")]))
    }
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(spawn: [HiveTaskSeed(nodeID: HiveNodeID("B"))])
    }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("J")) { _ in HiveNodeOutput(next: .end) }
    builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("J"))

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t8"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }
    let step3Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 3 ? node : nil
    }

    #expect(step1Tasks.contains(HiveNodeID("J")))
    #expect(step3Tasks == [HiveNodeID("J")])
}

@Test("Join barrier consumes only when available")
func testJoinBarrier_ConsumeOnlyWhenAvailable() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addNode(HiveNodeID("J")) { _ in HiveNodeOutput(next: .nodes([HiveNodeID("A"), HiveNodeID("B")])) }
    builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("J"))

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t9"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step1Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 1 ? node : nil
    }
    let step3Tasks = events.compactMap { event -> HiveNodeID? in
        guard case let .taskStarted(node, _) = event.kind else { return nil }
        return event.id.stepIndex == 3 ? node : nil
    }

    #expect(step1Tasks == [HiveNodeID("J")])
    #expect(step3Tasks == [HiveNodeID("J")])
}

@Test("Unknown channel write fails without commit")
func testUnknownChannelWrite_FailsNoCommit() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("known"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let knownKey = HiveChannelKey<Schema, Int>(HiveChannelID("known"))
    let unknownKey = HiveChannelKey<Schema, Int>(HiveChannelID("unknown"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(unknownKey, 1)])
    }

    let graph = try builder.compile()
    let runtime = HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("t10"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }

    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .unknownChannelID(let id):
            #expect(id.rawValue == "unknown")
        default:
            #expect(Bool(false))
        }
    }

    let events = await eventsTask.value
    let hasWriteApplied = events.contains { event in
        if case .writeApplied = event.kind { return true }
        return false
    }
    let hasStepFinished = events.contains { event in
        if case .stepFinished = event.kind { return true }
        return false
    }

    #expect(hasWriteApplied == false)
    #expect(hasStepFinished == false)

    if let store = await runtime.getLatestStore(threadID: HiveThreadID("t10")) {
        let value = try store.get(knownKey)
        #expect(value == 0)
    } else {
        #expect(Bool(false))
    }
}
