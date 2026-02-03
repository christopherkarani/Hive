import Foundation

public struct HiveRunEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started(threadID: HiveThreadID)
        case finished
        case interrupted(interruptID: HiveInterruptID)
        case resumed(interruptID: HiveInterruptID)
        case cancelled
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveStepEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started(stepIndex: Int, frontierCount: Int)
        case finished(stepIndex: Int, nextFrontierCount: Int)
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveTaskEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started(node: HiveNodeID, taskID: HiveTaskID)
        case finished(node: HiveNodeID, taskID: HiveTaskID)
        case failed(node: HiveNodeID, taskID: HiveTaskID, errorDescription: String)
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveWriteEvent: Sendable, Equatable {
    public let id: HiveEventID
    public let metadata: [String: String]
    public let channelID: HiveChannelID
    public let payloadHash: String
}

public struct HiveCheckpointEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case saved(checkpointID: HiveCheckpointID)
        case loaded(checkpointID: HiveCheckpointID)
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveModelEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started(model: String)
        case token(text: String)
        case finished
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveToolEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case started(name: String)
        case finished(name: String, success: Bool)
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveDebugEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case streamBackpressure(droppedModelTokenEvents: Int, droppedDebugEvents: Int)
        case customDebug(name: String)
    }

    public let id: HiveEventID
    public let metadata: [String: String]
    public let kind: Kind
}

public struct HiveEventStreamViews: Sendable {
    private let hub: HiveEventStreamViewsHub

    public init(_ source: AsyncThrowingStream<HiveEvent, Error>) {
        self.hub = HiveEventStreamViewsHub(source: source)
    }

    public func runs() -> AsyncThrowingStream<HiveRunEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .runStarted(let threadID):
                return HiveRunEvent(id: event.id, metadata: event.metadata, kind: .started(threadID: threadID))
            case .runFinished:
                return HiveRunEvent(id: event.id, metadata: event.metadata, kind: .finished)
            case .runInterrupted(let interruptID):
                return HiveRunEvent(id: event.id, metadata: event.metadata, kind: .interrupted(interruptID: interruptID))
            case .runResumed(let interruptID):
                return HiveRunEvent(id: event.id, metadata: event.metadata, kind: .resumed(interruptID: interruptID))
            case .runCancelled:
                return HiveRunEvent(id: event.id, metadata: event.metadata, kind: .cancelled)
            default:
                return nil
            }
        }
    }

    public func steps() -> AsyncThrowingStream<HiveStepEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .stepStarted(let stepIndex, let frontierCount):
                return HiveStepEvent(
                    id: event.id,
                    metadata: event.metadata,
                    kind: .started(stepIndex: stepIndex, frontierCount: frontierCount)
                )
            case .stepFinished(let stepIndex, let nextFrontierCount):
                return HiveStepEvent(
                    id: event.id,
                    metadata: event.metadata,
                    kind: .finished(stepIndex: stepIndex, nextFrontierCount: nextFrontierCount)
                )
            default:
                return nil
            }
        }
    }

    public func tasks() -> AsyncThrowingStream<HiveTaskEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .taskStarted(let node, let taskID):
                return HiveTaskEvent(id: event.id, metadata: event.metadata, kind: .started(node: node, taskID: taskID))
            case .taskFinished(let node, let taskID):
                return HiveTaskEvent(id: event.id, metadata: event.metadata, kind: .finished(node: node, taskID: taskID))
            case .taskFailed(let node, let taskID, let errorDescription):
                return HiveTaskEvent(
                    id: event.id,
                    metadata: event.metadata,
                    kind: .failed(node: node, taskID: taskID, errorDescription: errorDescription)
                )
            default:
                return nil
            }
        }
    }

    public func writes() -> AsyncThrowingStream<HiveWriteEvent, Error> {
        makeViewStream { event in
            guard case .writeApplied(let channelID, let payloadHash) = event.kind else { return nil }
            return HiveWriteEvent(id: event.id, metadata: event.metadata, channelID: channelID, payloadHash: payloadHash)
        }
    }

    public func checkpoints() -> AsyncThrowingStream<HiveCheckpointEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .checkpointSaved(let checkpointID):
                return HiveCheckpointEvent(id: event.id, metadata: event.metadata, kind: .saved(checkpointID: checkpointID))
            case .checkpointLoaded(let checkpointID):
                return HiveCheckpointEvent(id: event.id, metadata: event.metadata, kind: .loaded(checkpointID: checkpointID))
            default:
                return nil
            }
        }
    }

    public func model() -> AsyncThrowingStream<HiveModelEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .modelInvocationStarted(let model):
                return HiveModelEvent(id: event.id, metadata: event.metadata, kind: .started(model: model))
            case .modelToken(let text):
                return HiveModelEvent(id: event.id, metadata: event.metadata, kind: .token(text: text))
            case .modelInvocationFinished:
                return HiveModelEvent(id: event.id, metadata: event.metadata, kind: .finished)
            default:
                return nil
            }
        }
    }

    public func tools() -> AsyncThrowingStream<HiveToolEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .toolInvocationStarted(let name):
                return HiveToolEvent(id: event.id, metadata: event.metadata, kind: .started(name: name))
            case .toolInvocationFinished(let name, let success):
                return HiveToolEvent(id: event.id, metadata: event.metadata, kind: .finished(name: name, success: success))
            default:
                return nil
            }
        }
    }

    public func debug() -> AsyncThrowingStream<HiveDebugEvent, Error> {
        makeViewStream { event in
            switch event.kind {
            case .streamBackpressure(let droppedModelTokenEvents, let droppedDebugEvents):
                return HiveDebugEvent(
                    id: event.id,
                    metadata: event.metadata,
                    kind: .streamBackpressure(
                        droppedModelTokenEvents: droppedModelTokenEvents,
                        droppedDebugEvents: droppedDebugEvents
                    )
                )
            case .customDebug(let name):
                return HiveDebugEvent(id: event.id, metadata: event.metadata, kind: .customDebug(name: name))
            default:
                return nil
            }
        }
    }

    private func makeViewStream<T: Sendable>(
        _ transform: @escaping @Sendable (HiveEvent) -> T?
    ) -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task {
                await hub.addSubscriber(
                    id: id,
                    onEvent: { event in
                        if let mapped = transform(event) {
                            continuation.yield(mapped)
                        }
                    },
                    onFinish: { result in
                        switch result {
                        case .success:
                            continuation.finish()
                        case .failure(let error):
                            continuation.finish(throwing: error)
                        }
                    }
                )
            }
            continuation.onTermination = { _ in
                Task { await hub.removeSubscriber(id: id) }
            }
        }
    }
}

actor HiveEventStreamViewsHub {
    private struct Subscriber {
        let onEvent: (HiveEvent) -> Void
        let onFinish: (Result<Void, Error>) -> Void
    }

    private let source: AsyncThrowingStream<HiveEvent, Error>
    private var subscribers: [UUID: Subscriber] = [:]
    private var pumpTask: Task<Void, Never>?
    private var finished: Result<Void, Error>?

    init(source: AsyncThrowingStream<HiveEvent, Error>) {
        self.source = source
    }

    func addSubscriber(
        id: UUID,
        onEvent: @escaping (HiveEvent) -> Void,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        if let finished {
            onFinish(finished)
            return
        }

        subscribers[id] = Subscriber(onEvent: onEvent, onFinish: onFinish)
        startPumpIfNeeded()
    }

    func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func startPumpIfNeeded() {
        guard pumpTask == nil else { return }
        pumpTask = Task.detached { [source] in
            do {
                for try await event in source {
                    await self.broadcast(event)
                }
                await self.finishAll(.success(()))
            } catch {
                await self.finishAll(.failure(error))
            }
        }
    }

    private func broadcast(_ event: HiveEvent) {
        for subscriber in subscribers.values {
            subscriber.onEvent(event)
        }
    }

    private func finishAll(_ result: Result<Void, Error>) {
        finished = result
        let current = subscribers.values
        subscribers.removeAll()
        pumpTask = nil

        for subscriber in current {
            subscriber.onFinish(result)
        }
    }
}
