import Foundation
import Testing
@testable import HiveCore

private enum TestError: Error { case expected }

private func makeEvent(
    index: UInt64,
    kind: HiveEventKind,
    metadata: [String: String] = [:]
) -> HiveEvent {
    let runID = HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let attemptID = HiveRunAttemptID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let id = HiveEventID(
        runID: runID,
        attemptID: attemptID,
        eventIndex: index,
        stepIndex: nil,
        taskOrdinal: nil
    )
    return HiveEvent(id: id, kind: kind, metadata: metadata)
}

private func makeSourceStream() -> (AsyncThrowingStream<HiveEvent, Error>, AsyncThrowingStream<HiveEvent, Error>.Continuation) {
    var captured: AsyncThrowingStream<HiveEvent, Error>.Continuation!
    let stream = AsyncThrowingStream<HiveEvent, Error> { continuation in
        captured = continuation
    }
    return (stream, captured)
}

private func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var items: [T] = []
    for try await item in stream {
        items.append(item)
    }
    return items
}

private actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        guard isSignaled == false else { return }
        isSignaled = true
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        if isSignaled {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    if isSignaled {
                        continuation.resume()
                        return
                    }
                    continuations[waiterID] = continuation
                }
            },
            onCancel: {
                Task {
                    await self.cancelWaiter(waiterID)
                }
            }
        )
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    func value() -> Bool {
        isSignaled
    }
}

private func waitForSignal(
    _ signal: AsyncSignal,
    maxYields: Int
) async -> Bool {
    for _ in 0..<max(1, maxYields) {
        if await signal.value() {
            return true
        }
        await Task.yield()
    }
    return await signal.value()
}

@Suite("HiveEventStreamViews", .serialized)
struct HiveEventStreamViewsTests {
@Test("steps() filters and preserves order")
func stepsViewFiltersAndPreservesOrder() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let task = Task { try await collect(views.steps()) }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .runStarted(threadID: HiveThreadID("t"))))
    continuation.yield(makeEvent(index: 1, kind: .stepStarted(stepIndex: 0, frontierCount: 1)))
    continuation.yield(makeEvent(index: 2, kind: .customDebug(name: "x")))
    continuation.yield(makeEvent(index: 3, kind: .stepFinished(stepIndex: 0, nextFrontierCount: 0)))
    continuation.finish()

    let events = try await task.value
    #expect(events.count == 2)
    #expect(events.map(\.id.eventIndex) == [1, 3])
}

@Test("tasks() filters task lifecycle events")
func tasksViewFilters() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let task = Task { try await collect(views.tasks()) }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .taskStarted(node: HiveNodeID("A"), taskID: HiveTaskID("t0"))))
    continuation.yield(makeEvent(index: 1, kind: .customDebug(name: "x")))
    continuation.yield(makeEvent(index: 2, kind: .taskFailed(node: HiveNodeID("A"), taskID: HiveTaskID("t0"), errorDescription: "boom")))
    continuation.finish()

    let events = try await task.value
    #expect(events.count == 2)
    #expect(events.map(\.id.eventIndex) == [0, 2])
}

@Test("debug() propagates errors from the source stream")
func debugViewPropagatesError() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let task = Task {
        _ = try await collect(views.debug())
    }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .customDebug(name: "x")))
    continuation.finish(throwing: TestError.expected)

    do {
        _ = try await task.value
        #expect(Bool(false))
    } catch TestError.expected {
        #expect(Bool(true))
    }
}

@Test("cancelling a view consumer stops promptly")
func viewCancellationStopsPromptly() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    actor Latch {
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func signal() {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
        }
    }

    let latch = Latch()
    let consume = Task {
        var seen: [UInt64] = []
        for try await event in views.debug() {
            try Task.checkCancellation()
            seen.append(event.id.eventIndex)
            if seen.count == 1 {
                await latch.signal()
            }
        }
        return seen
    }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .customDebug(name: "x")))
    await latch.wait()
    consume.cancel()
    await Task.yield()
    continuation.yield(makeEvent(index: 1, kind: .customDebug(name: "y")))
    continuation.yield(makeEvent(index: 2, kind: .customDebug(name: "z")))
    continuation.finish()

    do {
        let seen = try await consume.value
        #expect(seen == [0])
    } catch is CancellationError {
        #expect(Bool(true))
    }
}

@Test("dropping to zero subscribers keeps source alive for later subscribers")
func droppingAllSubscribersKeepsSourceAlive() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let terminated = AsyncSignal()
    let secondSubscriberReady = AsyncSignal()
    continuation.onTermination = { @Sendable _ in
        Task {
            await terminated.signal()
        }
    }

    let firstConsumer = Task {
        var iterator = views.debug().makeAsyncIterator()
        _ = try await iterator.next()
    }

    await Task.yield()
    continuation.yield(makeEvent(index: 0, kind: .customDebug(name: "x")))
    _ = try await firstConsumer.value

    for _ in 0 ..< 5 {
        await Task.yield()
    }
    #expect(await terminated.value() == false)

    let probeIndex: UInt64 = 9_999
    let secondConsumer = Task {
        var indices: [UInt64] = []
        for try await event in views.debug() {
            if event.id.eventIndex == probeIndex {
                await secondSubscriberReady.signal()
                continue
            }
            indices.append(event.id.eventIndex)
        }
        return indices
    }

    let probeEmitter = Task {
        while Task.isCancelled == false {
            continuation.yield(makeEvent(index: probeIndex, kind: .customDebug(name: "probe")))
            await Task.yield()
        }
    }
    let secondSubscriberObservedProbe = await waitForSignal(secondSubscriberReady, maxYields: 50_000)
    probeEmitter.cancel()
    _ = await probeEmitter.result
    #expect(secondSubscriberObservedProbe)

    continuation.yield(makeEvent(index: 1, kind: .customDebug(name: "y")))
    continuation.finish()

    let eventIndices = try await secondConsumer.value
    #expect(eventIndices == [1])

    let terminatedAfterFinish = await waitForSignal(terminated, maxYields: 50_000)
    #expect(terminatedAfterFinish)
}

@Test("dropping the last view releases the source pump")
func droppingLastViewReleasesSourcePump() async throws {
    let (source, continuation) = makeSourceStream()
    let terminated = AsyncSignal()
    continuation.onTermination = { @Sendable _ in
        Task {
            await terminated.signal()
        }
    }

    var views: HiveEventStreamViews? = HiveEventStreamViews(source)
    var stream: AsyncThrowingStream<HiveDebugEvent, Error>? = views?.debug()
    let firstEvent: HiveDebugEvent? = try await {
        let consumerStream = stream!
        let consumer = Task {
            var iterator = consumerStream.makeAsyncIterator()
            return try await iterator.next()
        }

        await Task.yield()
        continuation.yield(makeEvent(index: 0, kind: .customDebug(name: "x")))
        return try await consumer.value
    }()
    #expect(firstEvent?.id.eventIndex == 0)

    stream = nil
    views = nil

    let terminatedAfterRelease = await waitForSignal(terminated, maxYields: 50_000)
    #expect(terminatedAfterRelease)
}
}
