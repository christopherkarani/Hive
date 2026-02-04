/// Type registry keyed by channel ID for runtime type validation.
public struct HiveChannelTypeRegistry<Schema: HiveSchema>: Sendable {
    private let valueTypeIDsByID: [HiveChannelID: String]

    public init(_ registry: HiveSchemaRegistry<Schema>) {
        var ids: [HiveChannelID: String] = [:]
        ids.reserveCapacity(registry.channelSpecs.count)
        for spec in registry.channelSpecs {
            ids[spec.id] = spec.valueTypeID
        }
        self.valueTypeIDsByID = ids
    }

    public func cast<Value: Sendable>(
        _ value: any Sendable,
        for key: HiveChannelKey<Schema, Value>
    ) throws -> Value {
        let expectedValueTypeID = String(reflecting: Value.self)
        guard let registered = valueTypeIDsByID[key.id] else {
            return try HiveChannelTypeRegistry.failUnknown(channelID: key.id)
        }
        if registered != expectedValueTypeID {
            return try HiveChannelTypeRegistry.fail(
                channelID: key.id,
                expected: registered,
                actual: expectedValueTypeID
            )
        }
        guard let typed = value as? Value else {
            let actualValueTypeID = String(reflecting: type(of: value))
            return try HiveChannelTypeRegistry.fail(
                channelID: key.id,
                expected: expectedValueTypeID,
                actual: actualValueTypeID
            )
        }
        return typed
    }

    private static func failUnknown<T>(channelID: HiveChannelID) throws -> T {
        #if DEBUG
        preconditionFailure(
            "Hive channel ID not found in schema: \(channelID.rawValue)."
        )
        #else
        throw HiveRuntimeError.unknownChannelID(channelID)
        #endif
    }

    private static func fail<T>(
        channelID: HiveChannelID,
        expected: String,
        actual: String
    ) throws -> T {
        #if DEBUG
        preconditionFailure(
            "Hive channel type mismatch for \(channelID.rawValue): expected \(expected), got \(actual)."
        )
        #else
        throw HiveRuntimeError.channelTypeMismatch(
            channelID: channelID,
            expectedValueTypeID: expected,
            actualValueTypeID: actual
        )
        #endif
    }
}
