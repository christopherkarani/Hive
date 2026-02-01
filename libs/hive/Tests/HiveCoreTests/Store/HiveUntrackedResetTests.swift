import Testing
@testable import HiveCore

private enum UntrackedResetSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<UntrackedResetSchema>] {
        let reducer = HiveReducer<Int> { current, update in current + update }

        let trackedKey = HiveChannelKey<UntrackedResetSchema, Int>(HiveChannelID("tracked"))
        let untrackedKey = HiveChannelKey<UntrackedResetSchema, Int>(HiveChannelID("scratch"))

        let trackedSpec = HiveChannelSpec(
            key: trackedKey,
            scope: .global,
            reducer: reducer,
            initial: { 0 },
            persistence: .checkpointed
        )

        let untrackedSpec = HiveChannelSpec(
            key: untrackedKey,
            scope: .global,
            reducer: reducer,
            initial: { 10 },
            persistence: .untracked
        )

        return [AnyHiveChannelSpec(trackedSpec), AnyHiveChannelSpec(untrackedSpec)]
    }
}

@Test("Untracked channels reset to initialCache on checkpoint load")
func testUntrackedChannels_ResetOnCheckpointLoad() throws {
    let registry = try HiveSchemaRegistry<UntrackedResetSchema>()
    let cache = HiveInitialCache(registry: registry)

    let trackedKey = HiveChannelKey<UntrackedResetSchema, Int>(HiveChannelID("tracked"))
    let untrackedKey = HiveChannelKey<UntrackedResetSchema, Int>(HiveChannelID("scratch"))

    var runningStore = HiveGlobalStore(registry: registry, initialCache: cache)
    try runningStore.set(trackedKey, 1)
    try runningStore.set(untrackedKey, 99)

    let checkpointedValues: [HiveChannelID: any Sendable] = [trackedKey.id: 7]
    let reloadedStore = try HiveGlobalStore(
        registry: registry,
        initialCache: cache,
        checkpointedValuesByID: checkpointedValues
    )

    #expect(try reloadedStore.get(trackedKey) == 7)
    #expect(try reloadedStore.get(untrackedKey) == 10)
}
