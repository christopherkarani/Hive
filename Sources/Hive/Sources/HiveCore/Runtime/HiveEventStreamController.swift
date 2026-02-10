import Foundation

internal enum HiveEventEnqueueResult: Sendable {
    case enqueued
    case coalescedModelToken
    case droppedModelToken
    case droppedDebug
    case terminated
}

internal final class HiveEventStreamController: @unchecked Sendable {
    private enum FinishState {
        case finished
        case failed(Error)
    }

    private enum DrainState {
        case hasEvent
        case finished
        case failed(Error)
    }

    private let capacity: Int
    private let condition = NSCondition()

    private var queue: [HiveEvent] = []
    private var finishState: FinishState?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.queue.reserveCapacity(min(64, self.capacity))
    }

    func makeStream() -> AsyncThrowingStream<HiveEvent, Error> {
        // Use a `.bufferingOldest(...)` continuation so already-buffered events are preserved.
        // When the continuation buffer is full, `yield` reports `.dropped` and the new element was not accepted.
        //
        // NOTE: We keep a minimum continuation buffer to avoid small `eventBufferCapacity` values causing
        // excessive drops of important events in tests and UI streams.
        AsyncThrowingStream(HiveEvent.self, bufferingPolicy: .bufferingOldest(max(64, capacity))) { continuation in
            Task.detached(priority: .userInitiated) {
                await self.pump(into: continuation)
            }
        }
    }

    func finish() {
        condition.lock()
        if finishState == nil {
            finishState = .finished
        }
        condition.broadcast()
        condition.unlock()
    }

    func finish(throwing error: Error) {
        condition.lock()
        if finishState == nil {
            finishState = .failed(error)
        }
        condition.broadcast()
        condition.unlock()
    }

    func enqueue(
        eventIndex: UInt64,
        runID: HiveRunID,
        attemptID: HiveRunAttemptID,
        kind: HiveEventKind,
        stepIndex: Int?,
        taskOrdinal: Int?,
        metadata: [String: String],
        treatAsNonDroppable: Bool = false
    ) -> HiveEventEnqueueResult {
        condition.lock()
        defer { condition.unlock() }

        if finishState != nil {
            return .terminated
        }

        if treatAsNonDroppable == false, isDroppable(kind) {
            if queue.count >= capacity {
                if case let .modelToken(text) = kind,
                   stepIndex != nil,
                   taskOrdinal != nil,
                   tryCoalesceModelToken(text: text, stepIndex: stepIndex!, taskOrdinal: taskOrdinal!)
                {
                    return .coalescedModelToken
                }

                if isDroppableModelToken(kind) { return .droppedModelToken }
                return .droppedDebug
            }

            let id = HiveEventID(
                runID: runID,
                attemptID: attemptID,
                eventIndex: eventIndex,
                stepIndex: stepIndex,
                taskOrdinal: taskOrdinal
            )
            queue.append(HiveEvent(id: id, kind: kind, metadata: metadata))
            condition.signal()
            return .enqueued
        }

        while queue.count >= capacity, finishState == nil {
            condition.wait()
        }

        if finishState != nil {
            return .terminated
        }

        let id = HiveEventID(
            runID: runID,
            attemptID: attemptID,
            eventIndex: eventIndex,
            stepIndex: stepIndex,
            taskOrdinal: taskOrdinal
        )
        queue.append(HiveEvent(id: id, kind: kind, metadata: metadata))
        condition.signal()
        return .enqueued
    }

    func pump(into continuation: AsyncThrowingStream<HiveEvent, Error>.Continuation) async {
        while true {
            let state = drainState()
            switch state {
            case .hasEvent:
                while true {
                    guard let event = snapshotFirst() else { break }
                    switch continuation.yield(event) {
                    case .enqueued:
                        consumeFirst()
                        break
                    case .dropped:
                        // `.bufferingOldest` reports `.dropped` when this event could not be delivered.
                        // Droppable events are intentionally discarded; non-droppable events must stay queued
                        // and retry until a consumer makes space.
                        if isDroppable(event.kind) {
                            consumeFirst()
                        } else {
                            await Task.yield()
                        }
                        break
                    case .terminated:
                        return
                    @unknown default:
                        consumeFirst()
                        break
                    }
                }
            case .finished:
                continuation.finish()
                return
            case .failed(let error):
                continuation.finish(throwing: error)
                return
            }
        }
    }

    private func drainState() -> DrainState {
        condition.lock()
        while queue.isEmpty, finishState == nil {
            condition.wait()
        }

        if !queue.isEmpty {
            condition.unlock()
            return .hasEvent
        }

        let state = finishState
        condition.unlock()

        switch state {
        case .none, .some(.finished):
            return .finished
        case .some(.failed(let error)):
            return .failed(error)
        }
    }

    private func snapshotFirst() -> HiveEvent? {
        condition.lock()
        let first = queue.first
        condition.unlock()
        return first
    }

    private func consumeFirst() {
        condition.lock()
        if !queue.isEmpty {
            queue.removeFirst()
            condition.broadcast()
        }
        condition.unlock()
    }

    private func tryCoalesceModelToken(text: String, stepIndex: Int, taskOrdinal: Int) -> Bool {
        guard let last = queue.last else { return false }
        guard last.id.stepIndex == stepIndex, last.id.taskOrdinal == taskOrdinal else { return false }
        guard case let .modelToken(existing) = last.kind else { return false }
        let coalesced = HiveEvent(
            id: last.id,
            kind: .modelToken(text: existing + text),
            metadata: last.metadata
        )
        queue[queue.count - 1] = coalesced
        return true
    }

    private func isDroppable(_ kind: HiveEventKind) -> Bool {
        isDroppableModelToken(kind) || isDroppableDebug(kind)
    }

    private func isDroppableModelToken(_ kind: HiveEventKind) -> Bool {
        if case .modelToken = kind { return true }
        return false
    }

    private func isDroppableDebug(_ kind: HiveEventKind) -> Bool {
        if case .customDebug = kind { return true }
        return false
    }
}
