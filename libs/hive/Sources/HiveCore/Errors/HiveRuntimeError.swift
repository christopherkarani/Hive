/// Runtime errors thrown during Hive execution.
public enum HiveRuntimeError: Error, Sendable {
    /// Attempted to access a channel ID that is not present in the schema.
    case unknownChannelID(HiveChannelID)
    /// Stored value type does not match the expected channel value type.
    case channelTypeMismatch(
        channelID: HiveChannelID,
        expectedValueTypeID: String,
        actualValueTypeID: String
    )
    /// Channel scope does not match the store being accessed.
    case scopeMismatch(
        channelID: HiveChannelID,
        expected: HiveChannelScope,
        actual: HiveChannelScope
    )
    /// Required codec is missing for a channel.
    case missingCodec(channelID: HiveChannelID)
    /// Task-local fingerprint encoding failed for the selected channel.
    case taskLocalFingerprintEncodeFailed(
        channelID: HiveChannelID,
        errorDescription: String
    )
}
