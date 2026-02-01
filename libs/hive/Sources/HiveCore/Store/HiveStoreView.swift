/// Read-only composed view of global store, task-local overlay, and initial cache.
public struct HiveStoreView<Schema: HiveSchema>: Sendable {
    private let access: HiveStoreSupport<Schema>
    private let global: HiveGlobalStore<Schema>
    private let taskLocal: HiveTaskLocalStore<Schema>
    private let initialCache: HiveInitialCache<Schema>

    init(
        global: HiveGlobalStore<Schema>,
        taskLocal: HiveTaskLocalStore<Schema>,
        initialCache: HiveInitialCache<Schema>,
        registry: HiveSchemaRegistry<Schema>
    ) {
        self.access = HiveStoreSupport(registry: registry)
        self.global = global
        self.taskLocal = taskLocal
        self.initialCache = initialCache
    }

    public func get<Value: Sendable>(_ key: HiveChannelKey<Schema, Value>) throws -> Value {
        let spec = try access.requireSpec(for: key.id)
        switch spec.scope {
        case .global:
            return try global.get(key)
        case .taskLocal:
            if let overlay = taskLocal.valueAny(for: key.id) {
                return try access.cast(overlay, for: key, spec: spec)
            }
            let initialValue = try initialCache.valueAny(for: key.id)
            return try access.cast(initialValue, for: key, spec: spec)
        }
    }
}
