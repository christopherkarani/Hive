import Foundation
import Testing
@testable import HiveCore

private actor CompletionFlag {
    private(set) var done = false

    func markDone() {
        done = true
    }
}

@Test("Non-droppable events are not consumed when continuation reports dropped")
func nonDroppableEventsAreRetriedUnderBackpressure() async throws {
    let controller = HiveEventStreamController(capacity: 65)
    let stream = controller.makeStream()

    let runID = HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)
    let attemptID = HiveRunAttemptID(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    let completion = CompletionFlag()

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
        await completion.markDone()
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await completion.done == false)

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
