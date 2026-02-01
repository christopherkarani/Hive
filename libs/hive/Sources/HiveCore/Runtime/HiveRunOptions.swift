/// Policy controlling checkpoint save cadence.
public enum HiveCheckpointPolicy: Sendable {
    case disabled
    case everyStep
    case every(steps: Int)
    case onInterrupt
}

/// Runtime execution options for a run attempt.
public struct HiveRunOptions: Sendable {
    public let maxSteps: Int
    public let maxConcurrentTasks: Int
    public let checkpointPolicy: HiveCheckpointPolicy
    public let debugPayloads: Bool
    public let deterministicTokenStreaming: Bool
    public let eventBufferCapacity: Int
    public let outputProjectionOverride: HiveOutputProjection?

    public init(
        maxSteps: Int = 100,
        maxConcurrentTasks: Int = 8,
        checkpointPolicy: HiveCheckpointPolicy = .disabled,
        debugPayloads: Bool = false,
        deterministicTokenStreaming: Bool = false,
        eventBufferCapacity: Int = 4096,
        outputProjectionOverride: HiveOutputProjection? = nil
    ) {
        self.maxSteps = maxSteps
        self.maxConcurrentTasks = maxConcurrentTasks
        self.checkpointPolicy = checkpointPolicy
        self.debugPayloads = debugPayloads
        self.deterministicTokenStreaming = deterministicTokenStreaming
        self.eventBufferCapacity = eventBufferCapacity
        self.outputProjectionOverride = outputProjectionOverride
    }
}
