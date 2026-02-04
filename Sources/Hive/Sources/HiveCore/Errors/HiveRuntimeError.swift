/// Runtime errors thrown during Hive execution.
public enum HiveRuntimeError: Error, Sendable {
    case invalidRunOptions(String)

    case stepIndexOutOfRange(stepIndex: Int)
    case taskOrdinalOutOfRange(ordinal: Int)

    case checkpointStoreMissing
    case checkpointVersionMismatch(
        expectedSchema: String,
        expectedGraph: String,
        foundSchema: String,
        foundGraph: String
    )
    case checkpointDecodeFailed(channelID: HiveChannelID, errorDescription: String)
    case checkpointEncodeFailed(channelID: HiveChannelID, errorDescription: String)
    case checkpointCorrupt(field: String, errorDescription: String)
    case interruptPending(interruptID: HiveInterruptID)
    case noCheckpointToResume
    case noInterruptToResume
    case resumeInterruptMismatch(expected: HiveInterruptID, found: HiveInterruptID)

    case unknownNodeID(HiveNodeID)
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

    case updatePolicyViolation(channelID: HiveChannelID, policy: HiveUpdatePolicy, writeCount: Int)
    case taskLocalWriteNotAllowed
    case invalidMessagesUpdate
    case missingTaskLocalValue(channelID: HiveChannelID)

    case modelClientMissing
    case modelStreamInvalid(String)
    case toolRegistryMissing
}
