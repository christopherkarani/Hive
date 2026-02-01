/// Output value for a projected channel.
public struct HiveProjectedChannelValue: Sendable {
    public let id: HiveChannelID
    public let value: any Sendable

    public init(id: HiveChannelID, value: any Sendable) {
        self.id = id
        self.value = value
    }
}

/// Output of a completed run attempt.
public enum HiveRunOutput<Schema: HiveSchema>: Sendable {
    case fullStore(HiveGlobalStore<Schema>)
    case channels([HiveProjectedChannelValue])
}

/// Terminal result of a run attempt.
public enum HiveRunOutcome<Schema: HiveSchema>: Sendable {
    case finished(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
    case interrupted(interruption: HiveInterruption<Schema>)
    case cancelled(output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
    case outOfSteps(maxSteps: Int, output: HiveRunOutput<Schema>, checkpointID: HiveCheckpointID?)
}

/// Handle for observing a running attempt.
public struct HiveRunHandle<Schema: HiveSchema>: Sendable {
    public let runID: HiveRunID
    public let attemptID: HiveRunAttemptID
    public let events: AsyncThrowingStream<HiveEvent, Error>
    public let outcome: Task<HiveRunOutcome<Schema>, Error>

    public init(
        runID: HiveRunID,
        attemptID: HiveRunAttemptID,
        events: AsyncThrowingStream<HiveEvent, Error>,
        outcome: Task<HiveRunOutcome<Schema>, Error>
    ) {
        self.runID = runID
        self.attemptID = attemptID
        self.events = events
        self.outcome = outcome
    }
}

/// Context passed to Schema.inputWrites before step 0.
public struct HiveInputContext: Sendable {
    public let threadID: HiveThreadID
    public let runID: HiveRunID
    public let stepIndex: Int

    public init(threadID: HiveThreadID, runID: HiveRunID, stepIndex: Int) {
        self.threadID = threadID
        self.runID = runID
        self.stepIndex = stepIndex
    }
}
