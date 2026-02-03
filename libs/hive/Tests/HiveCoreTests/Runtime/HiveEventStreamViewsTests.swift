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

@Test("steps() filters and preserves order")
func stepsViewFiltersAndPreservesOrder() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let task = Task { try await collect(views.steps()) }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .runStarted(threadID: HiveThreadID("t"))))
    continuation.yield(makeEvent(index: 1, kind: .stepStarted(stepIndex: 0, frontierCount: 1)))
    continuation.yield(makeEvent(index: 2, kind: .modelToken(text: "x")))
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
    continuation.yield(makeEvent(index: 1, kind: .modelToken(text: "x")))
    continuation.yield(makeEvent(index: 2, kind: .taskFailed(node: HiveNodeID("A"), taskID: HiveTaskID("t0"), errorDescription: "boom")))
    continuation.finish()

    let events = try await task.value
    #expect(events.count == 2)
    #expect(events.map(\.id.eventIndex) == [0, 2])
}

@Test("model() propagates errors from the source stream")
func modelViewPropagatesError() async throws {
    let (source, continuation) = makeSourceStream()
    let views = HiveEventStreamViews(source)

    let task = Task {
        _ = try await collect(views.model())
    }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .modelToken(text: "x")))
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
        for try await event in views.model() {
            try Task.checkCancellation()
            seen.append(event.id.eventIndex)
            if seen.count == 1 {
                await latch.signal()
            }
        }
        return seen
    }
    await Task.yield()

    continuation.yield(makeEvent(index: 0, kind: .modelToken(text: "x")))
    await latch.wait()
    consume.cancel()
    await Task.yield()
    continuation.yield(makeEvent(index: 1, kind: .modelToken(text: "y")))
    continuation.yield(makeEvent(index: 2, kind: .modelToken(text: "z")))
    continuation.finish()

    do {
        let seen = try await consume.value
        #expect(seen == [0])
    } catch is CancellationError {
        #expect(Bool(true))
    }
}
