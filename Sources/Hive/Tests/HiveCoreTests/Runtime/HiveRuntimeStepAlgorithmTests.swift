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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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

@Test("Deterministic events follow canonical sequencing")
func testEventSequence_DeterministicEventsOrder() async throws {
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

    let aKey = HiveChannelKey<Schema, Int>(HiveChannelID("a"))
    let bKey = HiveChannelKey<Schema, Int>(HiveChannelID("b"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(bKey, 1), AnyHiveWrite(aKey, 2)], next: .end)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(aKey, 3), AnyHiveWrite(bKey, 4)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("evt-order"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let kinds = events.map(\.kind)
    #expect(kinds.count == 10)

    guard let first = kinds.first, case .runStarted = first else { #expect(Bool(false)); return }
    guard case .stepStarted(stepIndex: 0, frontierCount: 2) = kinds[1] else { #expect(Bool(false)); return }
    guard case .taskStarted(node: HiveNodeID("A"), _) = kinds[2] else { #expect(Bool(false)); return }
    guard case .taskStarted(node: HiveNodeID("B"), _) = kinds[3] else { #expect(Bool(false)); return }
    guard case .taskFinished(node: HiveNodeID("A"), _) = kinds[4] else { #expect(Bool(false)); return }
    guard case .taskFinished(node: HiveNodeID("B"), _) = kinds[5] else { #expect(Bool(false)); return }

    guard case let .writeApplied(channelID: firstChannel, payloadHash: firstHash) = kinds[6] else { #expect(Bool(false)); return }
    guard case let .writeApplied(channelID: secondChannel, payloadHash: secondHash) = kinds[7] else { #expect(Bool(false)); return }
    #expect(firstChannel.rawValue == "a")
    #expect(secondChannel.rawValue == "b")
    #expect(firstHash.count == 64)
    #expect(secondHash.count == 64)

    guard case .stepFinished(stepIndex: 0, nextFrontierCount: 0) = kinds[8] else { #expect(Bool(false)); return }
    guard let last = kinds.last, case .runFinished = last else { #expect(Bool(false)); return }
}

@Test("Failed step emits no stepFinished or writeApplied")
func testFailedStep_NoStepFinishedOrWriteApplied() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let knownKey = HiveChannelKey<Schema, Int>(HiveChannelID("known"))
            let spec = HiveChannelSpec(
                key: knownKey,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let unknownKey = HiveChannelKey<Schema, Int>(HiveChannelID("unknown"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(unknownKey, 1)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("failed-step"),
        input: (),
        options: HiveRunOptions()
    )

    let eventsTask = Task { await collectEventsAndError(handle.events) }
    var outcomeError: Error?
    do {
        _ = try await handle.outcome.value
        #expect(Bool(false))
        return
    } catch {
        outcomeError = error
    }

    let (events, eventsError) = await eventsTask.value
    #expect(eventsError != nil)

    if let outcomeError,
       let outcomeError = outcomeError as? HiveRuntimeError,
       let eventsError = eventsError as? HiveRuntimeError
    {
        switch (outcomeError, eventsError) {
        case let (.unknownChannelID(lhs), .unknownChannelID(rhs)):
            #expect(lhs.rawValue == rhs.rawValue)
        default:
            #expect(Bool(false))
        }
    } else {
        #expect(Bool(false))
    }

    #expect(events.contains { if case .stepStarted = $0.kind { return true }; return false })
    #expect(events.contains { if case .taskStarted = $0.kind { return true }; return false })
    #expect(events.contains { if case .taskFinished = $0.kind { return true }; return false })
    #expect(events.contains { if case .writeApplied = $0.kind { return true }; return false } == false)
    #expect(events.contains { if case .stepFinished = $0.kind { return true }; return false } == false)
}

@Test("writeApplied metadata follows debugPayloads")
func testDebugPayloads_WriteAppliedMetadata() async throws {
    struct IntBECodec: HiveCodec {
        typealias Value = Int
        let id: String = "int.be"

        func encode(_ value: Int) throws -> Data {
            var big = Int64(value).bigEndian
            return withUnsafeBytes(of: &big) { Data($0) }
        }

        func decode(_ data: Data) throws -> Int {
            guard data.count == MemoryLayout<Int64>.size else { throw HiveRuntimeError.invalidRunOptions("bad decode") }
            let raw = data.withUnsafeBytes { $0.load(as: Int64.self) }
            return Int(Int64(bigEndian: raw))
        }
    }

    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer.lastWriteWins(),
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntBECodec()),
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    func run(debugPayloads: Bool) async throws -> HiveEvent {
        var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
        builder.addNode(HiveNodeID("A")) { _ in
            HiveNodeOutput(writes: [AnyHiveWrite(valueKey, 42)], next: .end)
        }

        let graph = try builder.compile()
        let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

        let handle = await runtime.run(
            threadID: HiveThreadID(debugPayloads ? "debug-on" : "debug-off"),
            input: (),
            options: HiveRunOptions(debugPayloads: debugPayloads)
        )

        let eventsTask = Task { await collectEvents(handle.events) }
        _ = try await handle.outcome.value
        let events = await eventsTask.value

        guard let write = events.first(where: { if case .writeApplied = $0.kind { return true }; return false }) else {
            throw HiveRuntimeError.invalidRunOptions("missing writeApplied")
        }
        return write
    }

    let debugOff = try await run(debugPayloads: false)
    if case .writeApplied = debugOff.kind {
        #expect(debugOff.metadata["payload"] == nil)
        #expect(debugOff.metadata["payloadEncoding"] == nil)
    } else {
        #expect(Bool(false))
    }

    let debugOn = try await run(debugPayloads: true)
    guard case let .writeApplied(_, payloadHash) = debugOn.kind else { #expect(Bool(false)); return }

    let expectedBytes = withUnsafeBytes(of: Int64(42).bigEndian) { Data($0) }
    let expectedHash = SHA256.hash(data: expectedBytes).compactMap { String(format: "%02x", $0) }.joined()
    #expect(payloadHash == expectedHash)

    #expect(debugOn.metadata["valueTypeID"] == String(reflecting: Int.self))
    #expect(debugOn.metadata["codecID"] == "int.be")
    #expect(debugOn.metadata["payloadEncoding"] == "codec.base64")
    #expect(debugOn.metadata["payload"] == expectedBytes.base64EncodedString())
}

@Test("deterministicTokenStreaming buffers and orders stream events")
func testDeterministicTokenStreaming_BuffersStreamEvents() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { input in
        input.emitStream(.modelInvocationStarted(model: "m"), [:])
        input.emitStream(.modelToken(text: "A1"), [:])
        input.emitStream(.modelToken(text: "A2"), [:])
        input.emitStream(.modelInvocationFinished, [:])
        try await Task.sleep(nanoseconds: 50_000_000)
        return HiveNodeOutput(next: .end)
    }
    builder.addNode(HiveNodeID("B")) { input in
        input.emitStream(.modelInvocationStarted(model: "m"), [:])
        input.emitStream(.modelToken(text: "B1"), [:])
        input.emitStream(.modelInvocationFinished, [:])
        try await Task.sleep(nanoseconds: 5_000_000)
        return HiveNodeOutput(next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("det-stream"),
        input: (),
        options: HiveRunOptions(deterministicTokenStreaming: true)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step0 = events.filter { $0.id.stepIndex == 0 }
    let streamEvents = step0.filter { event in
        switch event.kind {
        case .modelInvocationStarted, .modelToken, .modelInvocationFinished, .toolInvocationStarted, .toolInvocationFinished, .customDebug:
            return true
        default:
            return false
        }
    }

    let ordinals = streamEvents.compactMap(\.id.taskOrdinal)
    #expect(ordinals.contains(0))
    #expect(ordinals.contains(1))

    if let firstOneIndex = ordinals.firstIndex(of: 1) {
        #expect(ordinals[firstOneIndex...].allSatisfy { $0 == 1 })
        #expect(ordinals[..<firstOneIndex].allSatisfy { $0 == 0 })
    } else {
        #expect(Bool(false))
    }

    let firstTaskFinishedIndex = step0.firstIndex { if case .taskFinished = $0.kind { return true }; return false }
    #expect(firstTaskFinishedIndex != nil)
    if let firstTaskFinishedIndex {
        let lastStreamIndex = step0.lastIndex { event in
            switch event.kind {
            case .modelInvocationStarted, .modelToken, .modelInvocationFinished, .toolInvocationStarted, .toolInvocationFinished, .customDebug:
                return true
            default:
                return false
            }
        }
        #expect(lastStreamIndex != nil)
        if let lastStreamIndex {
            #expect(lastStreamIndex < firstTaskFinishedIndex)
        }
    }
}

@Test("Backpressure coalesces and drops deterministically")
func testBackpressure_ModelTokensCoalesceAndDropDeterministically() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A"), HiveNodeID("B")])
    builder.addNode(HiveNodeID("A")) { input in
        input.emitStream(.modelToken(text: "A"), [:])
        input.emitDebug("d", [:])
        input.emitStream(.modelToken(text: "B"), [:])
        input.emitStream(.modelToken(text: "C"), [:]) // coalesce into "BC"
        input.emitDebug("d2", [:]) // drop
        return HiveNodeOutput(next: .end)
    }
    builder.addNode(HiveNodeID("B")) { input in
        input.emitStream(.modelToken(text: "X"), [:])
        input.emitStream(.modelToken(text: "Y"), [:])
        input.emitDebug("d0", [:])
        input.emitStream(.modelToken(text: "Z"), [:]) // drop
        input.emitDebug("d1", [:]) // drop
        return HiveNodeOutput(next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("backpressure"),
        input: (),
        options: HiveRunOptions(deterministicTokenStreaming: true, eventBufferCapacity: 3)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let step0 = events.filter { $0.id.stepIndex == 0 }
    let backpressureEvents = step0.compactMap { event -> (Int, Int)? in
        guard case let .streamBackpressure(droppedModelTokenEvents, droppedDebugEvents) = event.kind else { return nil }
        return (droppedModelTokenEvents, droppedDebugEvents)
    }
    #expect(backpressureEvents.count == 1)
    #expect(backpressureEvents.first?.0 == 1)
    #expect(backpressureEvents.first?.1 == 2)

    if let backpressureIndex = step0.firstIndex(where: { if case .streamBackpressure = $0.kind { return true }; return false }),
       let stepFinishedIndex = step0.firstIndex(where: { if case .stepFinished = $0.kind { return true }; return false })
    {
        #expect(backpressureIndex + 1 == stepFinishedIndex)
    } else {
        #expect(Bool(false))
    }

    let tokenTexts = step0.compactMap { event -> (Int?, String)? in
        guard case let .modelToken(text) = event.kind else { return nil }
        return (event.id.taskOrdinal, text)
    }
    #expect(tokenTexts.contains { $0.0 == 0 && $0.1.contains("BC") })
    #expect(tokenTexts.contains { $0.0 == 1 && $0.1 == "Z" } == false)
    #expect(step0.contains { if case .customDebug(name: "d1") = $0.kind { return true }; return false } == false)
}

@Test("deterministicTokenStreaming discards failed-attempt stream buffers")
func testDeterministicTokenStreaming_DiscardsFailedAttemptStreamBuffers() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    final class Attempts: @unchecked Sendable {
        var count = 0
    }
    let attempts = Attempts()

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(
        HiveNodeID("A"),
        retryPolicy: .exponentialBackoff(initialNanoseconds: 0, factor: 1, maxAttempts: 2, maxNanoseconds: 0)
    ) { input in
        attempts.count += 1
        if attempts.count == 1 {
            input.emitStream(.modelToken(text: "attempt1"), [:])
            throw HiveRuntimeError.invalidRunOptions("fail once")
        }
        input.emitStream(.modelToken(text: "attempt2"), [:])
        return HiveNodeOutput(next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

    let handle = await runtime.run(
        threadID: HiveThreadID("retry-stream"),
        input: (),
        options: HiveRunOptions(deterministicTokenStreaming: true)
    )

    let eventsTask = Task { await collectEvents(handle.events) }
    _ = try await handle.outcome.value
    let events = await eventsTask.value

    let tokenTexts = events.compactMap { event -> String? in
        guard case let .modelToken(text) = event.kind else { return nil }
        return text
    }
    #expect(tokenTexts.contains("attempt1") == false)
    #expect(tokenTexts.contains("attempt2"))

    let startedCount = events.filter { if case .taskStarted = $0.kind { return true }; return false }.count
    let finishedCount = events.filter { if case .taskFinished = $0.kind { return true }; return false }.count
    #expect(startedCount == 1)
    #expect(finishedCount == 1)
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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
    let runtime = try HiveRuntime(graph: graph, environment: makeEnvironment(context: ()))

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
