/// Overlay-only store for task-local channels.
public struct HiveTaskLocalStore<Schema: HiveSchema>: Sendable {
    public static var empty: HiveTaskLocalStore<Schema> {
        do {
            let registry = try HiveSchemaRegistry<Schema>()
            return HiveTaskLocalStore(registry: registry)
        } catch {
            preconditionFailure("Failed to build empty HiveTaskLocalStore: \(error)")
        }
    }

    private let access: HiveStoreSupport<Schema>
    private var valuesByID: [HiveChannelID: any Sendable]

    init(
        registry: HiveSchemaRegistry<Schema>,
        valuesByID: [HiveChannelID: any Sendable] = [:]
    ) {
        self.access = HiveStoreSupport(registry: registry)
        self.valuesByID = valuesByID
    }

    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value? {
        let spec = try access.requireScope(.taskLocal, for: key.id)
        guard let value = valuesByID[key.id] else {
            return nil
        }
        return try access.cast(value, for: key, spec: spec)
    }

    public mutating func set<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>, _ value: Value) throws {
        let spec = try access.requireScope(.taskLocal, for: key.id)
        try access.validateKeyType(key, spec: spec)
        valuesByID[key.id] = value
    }

    func valueAny(for id: HiveChannelID) -> (any Sendable)? {
        valuesByID[id]
    }
}
