import Testing
@testable import HiveCore

private enum StoreErrorSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<StoreErrorSchema>] {
        let reducer = HiveReducer<Int> { current, update in current + update }

        let globalKey = HiveChannelKey<StoreErrorSchema, Int>(HiveChannelID("global"))
        let taskLocalKey = HiveChannelKey<StoreErrorSchema, Int>(HiveChannelID("local"))

        let globalSpec = HiveChannelSpec(
            key: globalKey,
            scope: .global,
            reducer: reducer,
            initial: { 1 },
            persistence: .checkpointed
        )
        let taskLocalSpec = HiveChannelSpec(
            key: taskLocalKey,
            scope: .taskLocal,
            reducer: reducer,
            initial: { 2 },
            persistence: .checkpointed
        )

        return [AnyHiveChannelSpec(globalSpec), AnyHiveChannelSpec(taskLocalSpec)]
    }
}

private enum NonCheckpointedGlobalSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<NonCheckpointedGlobalSchema>] {
        let key = HiveChannelKey<NonCheckpointedGlobalSchema, Int>(HiveChannelID("untracked"))
        let spec = HiveChannelSpec(
            key: key,
            scope: .global,
            reducer: HiveReducer { current, update in current + update },
            initial: { 0 },
            persistence: .untracked
        )
        return [AnyHiveChannelSpec(spec)]
    }
}

private enum InvalidEmptyTaskLocalSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<InvalidEmptyTaskLocalSchema>] {
        let a = HiveChannelKey<InvalidEmptyTaskLocalSchema, Int>(HiveChannelID("dup"))
        let b = HiveChannelKey<InvalidEmptyTaskLocalSchema, Int>(HiveChannelID("dup"))
        let reducer = HiveReducer<Int> { current, update in current + update }
        return [
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: a,
                    scope: .taskLocal,
                    reducer: reducer,
                    initial: { 0 },
                    persistence: .checkpointed
                )
            ),
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: b,
                    scope: .taskLocal,
                    reducer: reducer,
                    initial: { 0 },
                    persistence: .checkpointed
                )
            ),
        ]
    }
}

@Test("Store unknown channel throws unknownChannelID")
func testStore_UnknownChannel_Throws() throws {
    let registry = try HiveSchemaRegistry<StoreErrorSchema>()
    let cache = HiveInitialCache(registry: registry)
    let global = try HiveGlobalStore(registry: registry, initialCache: cache)
    var taskLocal = HiveTaskLocalStore(registry: registry)
    let view = HiveStoreView(
        global: global,
        taskLocal: taskLocal,
        initialCache: cache,
        registry: registry
    )

    let missingKey = HiveChannelKey<StoreErrorSchema, Int>(HiveChannelID("missing"))

    do {
        _ = try global.get(missingKey)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .unknownChannelID(let id):
            #expect(id.rawValue == "missing")
        default:
            #expect(Bool(false))
        }
    }

    do {
        _ = try taskLocal.get(missingKey)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .unknownChannelID(let id):
            #expect(id.rawValue == "missing")
        default:
            #expect(Bool(false))
        }
    }

    do {
        try taskLocal.set(missingKey, 42)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .unknownChannelID(let id):
            #expect(id.rawValue == "missing")
        default:
            #expect(Bool(false))
        }
    }

    do {
        _ = try view.get(missingKey)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .unknownChannelID(let id):
            #expect(id.rawValue == "missing")
        default:
            #expect(Bool(false))
        }
    }
}

@Test("Store scope mismatch throws scopeMismatch")
func testStore_ScopeMismatch_Throws() throws {
    let registry = try HiveSchemaRegistry<StoreErrorSchema>()
    let cache = HiveInitialCache(registry: registry)
    let global = try HiveGlobalStore(registry: registry, initialCache: cache)
    var taskLocal = HiveTaskLocalStore(registry: registry)

    let globalKey = HiveChannelKey<StoreErrorSchema, Int>(HiveChannelID("global"))
    let taskLocalKey = HiveChannelKey<StoreErrorSchema, Int>(HiveChannelID("local"))

    do {
        _ = try global.get(taskLocalKey)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .scopeMismatch(let channelID, let expected, let actual):
            #expect(channelID.rawValue == "local")
            #expect(expected == .global)
            #expect(actual == .taskLocal)
        default:
            #expect(Bool(false))
        }
    }

    do {
        _ = try taskLocal.get(globalKey)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .scopeMismatch(let channelID, let expected, let actual):
            #expect(channelID.rawValue == "global")
            #expect(expected == .taskLocal)
            #expect(actual == .global)
        default:
            #expect(Bool(false))
        }
    }

    do {
        try taskLocal.set(globalKey, 10)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .scopeMismatch(let channelID, let expected, let actual):
            #expect(channelID.rawValue == "global")
            #expect(expected == .taskLocal)
            #expect(actual == .global)
        default:
            #expect(Bool(false))
        }
    }
}

@Test("Checkpointed override on non-checkpointed global throws checkpointOverrideNotCheckpointed")
func testGlobalStore_CheckpointOverrideNotCheckpointed_Throws() throws {
    let registry = try HiveSchemaRegistry<NonCheckpointedGlobalSchema>()
    let cache = HiveInitialCache(registry: registry)
    let channelID = HiveChannelID("untracked")

    do {
        _ = try HiveGlobalStore(
            registry: registry,
            initialCache: cache,
            checkpointedValuesByID: [channelID: 1]
        )
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointOverrideNotCheckpointed(let id):
            #expect(id == channelID)
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}

@Test("HiveTaskLocalStore.empty captures schema initialization errors as thrown errors")
func testTaskLocalStoreEmpty_InvalidSchemaThrowsOnAccess() {
    let store = HiveTaskLocalStore<InvalidEmptyTaskLocalSchema>.empty
    let key = HiveChannelKey<InvalidEmptyTaskLocalSchema, Int>(HiveChannelID("dup"))

    do {
        _ = try store.get(key)
        #expect(Bool(false))
    } catch let error as HiveCompilationError {
        switch error {
        case .duplicateChannelID(let id):
            #expect(id.rawValue == "dup")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}
