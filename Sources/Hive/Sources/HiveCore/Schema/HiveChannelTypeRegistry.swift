/// Type registry keyed by channel ID for runtime type validation.
public struct HiveChannelTypeRegistry<Schema: HiveSchema>: Sendable {
    private let valueTypeIDsByID: [HiveChannelID: String]
    private let objectIdentifiersByID: [HiveChannelID: ObjectIdentifier]

    public init(_ registry: HiveSchemaRegistry<Schema>) {
        var ids: [HiveChannelID: String] = [:]
        var oids: [HiveChannelID: ObjectIdentifier] = [:]
        ids.reserveCapacity(registry.channelSpecs.count)
        oids.reserveCapacity(registry.channelSpecs.count)
        for spec in registry.channelSpecs {
            ids[spec.id] = spec.valueTypeID
            if let oid = spec.valueObjectIdentifier {
                oids[spec.id] = oid
            }
        }
        self.valueTypeIDsByID = ids
        self.objectIdentifiersByID = oids
    }

    public func cast<Value: Sendable>(
        _ value: any Sendable,
        for key: HiveChannelKey<Schema, Value>
    ) throws -> Value {
        guard let _ = valueTypeIDsByID[key.id] else {
            return try HiveChannelTypeRegistry.failUnknown(channelID: key.id)
        }
        // Primary check: use ObjectIdentifier for reliable metatype comparison
        // that works correctly across module boundaries (unlike String(reflecting:)).
        if let registeredOID = objectIdentifiersByID[key.id] {
            let expectedOID = ObjectIdentifier(Value.self)
            if registeredOID != expectedOID {
                let expected = valueTypeIDsByID[key.id] ?? "unknown"
                let actual = String(reflecting: Value.self)
                return try HiveChannelTypeRegistry.fail(
                    channelID: key.id,
                    expected: expected,
                    actual: actual
                )
            }
        }
        guard let typed = value as? Value else {
            let expected = valueTypeIDsByID[key.id] ?? "unknown"
            let actualValueTypeID = String(reflecting: type(of: value))
            return try HiveChannelTypeRegistry.fail(
                channelID: key.id,
                expected: expected,
                actual: actualValueTypeID
            )
        }
        return typed
    }

    private static func failUnknown<T>(channelID: HiveChannelID) throws -> T {
        throw HiveRuntimeError.unknownChannelID(channelID)
    }

    private static func fail<T>(
        channelID: HiveChannelID,
        expected: String,
        actual: String
    ) throws -> T {
        throw HiveRuntimeError.channelTypeMismatch(
            channelID: channelID,
            expectedValueTypeID: expected,
            actualValueTypeID: actual
        )
    }
}
