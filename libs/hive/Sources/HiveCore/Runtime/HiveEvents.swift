/// Stable identifier for a run event.
public struct HiveEventID: Hashable, Codable, Sendable {
    public let runID: HiveRunID
    public let attemptID: HiveRunAttemptID
    public let eventIndex: UInt64
    public let stepIndex: Int?
    public let taskOrdinal: Int?

    public init(
        runID: HiveRunID,
        attemptID: HiveRunAttemptID,
        eventIndex: UInt64,
        stepIndex: Int?,
        taskOrdinal: Int?
    ) {
        self.runID = runID
        self.attemptID = attemptID
        self.eventIndex = eventIndex
        self.stepIndex = stepIndex
        self.taskOrdinal = taskOrdinal
    }
}

/// Event emitted by the runtime event stream.
public struct HiveEvent: Sendable {
    public let id: HiveEventID
    public let kind: HiveEventKind
    public let metadata: [String: String]

    public init(id: HiveEventID, kind: HiveEventKind, metadata: [String: String]) {
        self.id = id
        self.kind = kind
        self.metadata = metadata
    }
}

/// Event kinds emitted during a run.
public enum HiveEventKind: Sendable {
    case runStarted(threadID: HiveThreadID)
    case runFinished
    case runInterrupted(interruptID: HiveInterruptID)
    case runResumed(interruptID: HiveInterruptID)
    case runCancelled

    case stepStarted(stepIndex: Int, frontierCount: Int)
    case stepFinished(stepIndex: Int, nextFrontierCount: Int)

    case taskStarted(node: HiveNodeID, taskID: HiveTaskID)
    case taskFinished(node: HiveNodeID, taskID: HiveTaskID)
    case taskFailed(node: HiveNodeID, taskID: HiveTaskID, errorDescription: String)

    case writeApplied(channelID: HiveChannelID, payloadHash: String)
    case checkpointSaved(checkpointID: HiveCheckpointID)
    case checkpointLoaded(checkpointID: HiveCheckpointID)

    case modelInvocationStarted(model: String)
    case modelToken(text: String)
    case modelInvocationFinished

    case toolInvocationStarted(name: String)
    case toolInvocationFinished(name: String, success: Bool)

    case streamBackpressure(droppedModelTokenEvents: Int, droppedDebugEvents: Int)
    case customDebug(name: String)
}
