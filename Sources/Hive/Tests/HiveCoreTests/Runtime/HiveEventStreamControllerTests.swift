import Foundation
import Testing
@testable import HiveCore

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

@Test("Non-droppable events are not consumed when continuation reports dropped")
func nonDroppableEventsAreRetriedUnderBackpressure() async throws {
    let controller = HiveEventStreamController(capacity: 1)
    let stream = controller.makeStream()

    let runID = HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
    let attemptID = HiveRunAttemptID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    let completion = AsyncSignal()

    let producer = Task {
        for index in 0..<80 {
            _ = controller.enqueue(
                eventIndex: UInt64(index),
                runID: runID,
                attemptID: attemptID,
                kind: .stepStarted(stepIndex: index, frontierCount: 1),
                stepIndex: index,
                taskOrdinal: nil,
                metadata: [:]
            )
        }
        await completion.signal()
    }

    let completedWithoutConsumer = await waitForSignal(completion, maxYields: 10_000)
    #expect(completedWithoutConsumer == false)

    let consumeTask = Task { () async throws -> [HiveEvent] in
        var events: [HiveEvent] = []
        for try await event in stream {
            events.append(event)
            if events.count == 80 {
                return events
            }
        }
        return events
    }

    await producer.value
    let events = try await consumeTask.value
    controller.finish()

    #expect(events.count == 80)

    let stepIndexes = events.compactMap { event -> Int? in
        guard case .stepStarted = event.kind else { return nil }
        return event.id.stepIndex
    }
    #expect(stepIndexes == Array(0..<80))
}

@Test("Non-droppable producer unblocks when consumer terminates")
func nonDroppableProducerUnblocksWhenConsumerTerminates() async throws {
    let controller = HiveEventStreamController(capacity: 1)
    let stream = controller.makeStream()

    let runID = HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000020")!)
    let attemptID = HiveRunAttemptID(UUID(uuidString: "00000000-0000-0000-0000-000000000021")!)

    let firstEventSeen = AsyncSignal()
    let consumer = Task {
        do {
            for try await _ in stream {
                await firstEventSeen.signal()
            }
        } catch {}
    }

    _ = controller.enqueue(
        eventIndex: 0,
        runID: runID,
        attemptID: attemptID,
        kind: .stepStarted(stepIndex: 0, frontierCount: 1),
        stepIndex: 0,
        taskOrdinal: nil,
        metadata: [:]
    )
    let sawFirstEvent = await waitForSignal(firstEventSeen, maxYields: 50_000)
    #expect(sawFirstEvent)

    consumer.cancel()
    _ = await consumer.result

    let completion = AsyncSignal()
    let producer = Task {
        _ = controller.enqueue(
            eventIndex: 1,
            runID: runID,
            attemptID: attemptID,
            kind: .stepStarted(stepIndex: 1, frontierCount: 1),
            stepIndex: 1,
            taskOrdinal: nil,
            metadata: [:]
        )
        _ = controller.enqueue(
            eventIndex: 2,
            runID: runID,
            attemptID: attemptID,
            kind: .stepStarted(stepIndex: 2, frontierCount: 1),
            stepIndex: 2,
            taskOrdinal: nil,
            metadata: [:]
        )
        await completion.signal()
    }

    let completedBeforeForceFinish = await waitForSignal(completion, maxYields: 50_000)
    if completedBeforeForceFinish == false {
        // Ensure the task cannot leak if the controller is still blocked.
        controller.finish()
    }
    await producer.value

    #expect(completedBeforeForceFinish)
}
