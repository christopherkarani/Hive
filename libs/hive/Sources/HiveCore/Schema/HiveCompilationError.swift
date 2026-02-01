/// Compilation-time schema validation errors.
public enum HiveCompilationError: Error, Sendable {
    /// Multiple channel specs declare the same `HiveChannelID`.
    case duplicateChannelID(HiveChannelID)
    /// v1 restriction: `.taskLocal` channels must be `.checkpointed`.
    case invalidTaskLocalUntracked(channelID: HiveChannelID)
}
