import Testing
@testable import HiveCore

// MARK: - Minimal schema for cache tests

private enum CacheTestSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<CacheTestSchema>] {
        let key = HiveChannelKey<CacheTestSchema, Int>(HiveChannelID("counter"))
        let spec = HiveChannelSpec(
            key: key,
            scope: .global,
            reducer: HiveReducer { _, update in update },
            updatePolicy: .multi,
            initial: { 0 },
            persistence: .untracked
        )
        return [AnyHiveChannelSpec(spec)]
    }
}

private let counterKey = HiveChannelKey<CacheTestSchema, Int>(HiveChannelID("counter"))

private func makeOutput(value: Int = 0) -> HiveNodeOutput<CacheTestSchema> {
    HiveNodeOutput(
        writes: [AnyHiveWrite(counterKey, value)],
        next: .end
    )
}

// MARK: - Tests

@Suite("HiveNodeCache")
struct HiveNodeCacheTests {

    @Test("lookup returns nil for missing key")
    func lookupMissingKeyReturnsNil() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let policy = HiveCachePolicy<CacheTestSchema>.lru(maxEntries: 10)
        let result = cache.lookup(key: "missing", policy: policy, nowNanoseconds: 0)
        #expect(result == nil)
    }

    @Test("store and lookup returns stored output")
    func storeAndLookupReturnsOutput() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let policy = HiveCachePolicy<CacheTestSchema>.lru(maxEntries: 10)
        let output = makeOutput(value: 42)
        cache.store(key: "k1", output: output, policy: policy, nowNanoseconds: 0)
        let result = cache.lookup(key: "k1", policy: policy, nowNanoseconds: 0)
        #expect(result != nil)
    }

    @Test("lookup removes expired entry")
    func lookupRemovesExpiredEntry() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let ttlNs: UInt64 = 1_000
        let policy = HiveCachePolicy<CacheTestSchema>(
            maxEntries: 10,
            ttlNanoseconds: ttlNs,
            keyProvider: AnyHiveCacheKeyProvider { _, _ in "key" }
        )
        cache.store(key: "k1", output: makeOutput(), policy: policy, nowNanoseconds: 0)
        // Lookup at time before expiry succeeds
        #expect(cache.lookup(key: "k1", policy: policy, nowNanoseconds: 500) != nil)
        // Lookup at expiry returns nil and removes the entry
        #expect(cache.lookup(key: "k1", policy: policy, nowNanoseconds: 1_001) == nil)
        // Entry is gone — count drops to zero
        #expect(cache.entries.isEmpty)
    }

    @Test("TTL-based cache doesn't expire entries before TTL")
    func ttlEntryValidBeforeExpiry() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let ttlNs: UInt64 = 5_000_000_000  // 5 seconds
        let policy = HiveCachePolicy<CacheTestSchema>(
            maxEntries: 10,
            ttlNanoseconds: ttlNs,
            keyProvider: AnyHiveCacheKeyProvider { _, _ in "key" }
        )
        cache.store(key: "k1", output: makeOutput(), policy: policy, nowNanoseconds: 0)
        #expect(cache.lookup(key: "k1", policy: policy, nowNanoseconds: 4_999_999_999) != nil)
    }

    @Test("LRU eviction removes least-recently-used entry when at capacity")
    func lruEvictionRemovesLRUEntry() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let policy = HiveCachePolicy<CacheTestSchema>.lru(maxEntries: 3)

        // Fill to capacity
        cache.store(key: "k1", output: makeOutput(value: 1), policy: policy, nowNanoseconds: 0)
        cache.store(key: "k2", output: makeOutput(value: 2), policy: policy, nowNanoseconds: 0)
        cache.store(key: "k3", output: makeOutput(value: 3), policy: policy, nowNanoseconds: 0)

        // Access k1 to make it most-recently-used; k2 becomes LRU
        _ = cache.lookup(key: "k1", policy: policy, nowNanoseconds: 0)
        _ = cache.lookup(key: "k3", policy: policy, nowNanoseconds: 0)

        // Adding k4 should evict k2 (LRU)
        cache.store(key: "k4", output: makeOutput(value: 4), policy: policy, nowNanoseconds: 0)

        #expect(cache.entries.count == 3)
        #expect(cache.lookup(key: "k2", policy: policy, nowNanoseconds: 0) == nil)
        #expect(cache.lookup(key: "k1", policy: policy, nowNanoseconds: 0) != nil)
        #expect(cache.lookup(key: "k3", policy: policy, nowNanoseconds: 0) != nil)
        #expect(cache.lookup(key: "k4", policy: policy, nowNanoseconds: 0) != nil)
    }

    @Test("store overwrites existing entry with same key")
    func storeOverwritesExistingEntry() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let policy = HiveCachePolicy<CacheTestSchema>.lru(maxEntries: 10)

        cache.store(key: "k1", output: makeOutput(value: 1), policy: policy, nowNanoseconds: 0)
        cache.store(key: "k1", output: makeOutput(value: 99), policy: policy, nowNanoseconds: 0)

        // Only one entry with the same key
        #expect(cache.entries.count == 1)
    }

    @Test("expired entries count against maxEntries before removal")
    func expiredEntriesCountAgainstMaxEntriesUntilEvicted() {
        var cache = HiveNodeCache<CacheTestSchema>()
        let ttlNs: UInt64 = 1_000
        let policy = HiveCachePolicy<CacheTestSchema>(
            maxEntries: 2,
            ttlNanoseconds: ttlNs,
            keyProvider: AnyHiveCacheKeyProvider { _, _ in "key" }
        )

        // Fill to capacity (both entries expire at ns=1000)
        cache.store(key: "k1", output: makeOutput(value: 1), policy: policy, nowNanoseconds: 0)
        cache.store(key: "k2", output: makeOutput(value: 2), policy: policy, nowNanoseconds: 0)

        // Trigger eviction by accessing the expired k1 — it should be removed
        let expired = cache.lookup(key: "k1", policy: policy, nowNanoseconds: 2_000)
        #expect(expired == nil)
        #expect(cache.entries.count == 1)  // k2 still there (but also expired)
    }

    @Test("lruTTL factory produces correct TTL nanoseconds without overflow")
    func lruTTLFactoryNoOverflow() {
        // 1 second — straightforward case
        let policy1s = HiveCachePolicy<CacheTestSchema>.lruTTL(maxEntries: 1, ttl: .seconds(1))
        #expect(policy1s.ttlNanoseconds == 1_000_000_000)

        // Large duration — must not overflow
        let policyLarge = HiveCachePolicy<CacheTestSchema>.lruTTL(maxEntries: 1, ttl: .seconds(Int64.max / 2))
        #expect(policyLarge.ttlNanoseconds != nil)
    }
}
