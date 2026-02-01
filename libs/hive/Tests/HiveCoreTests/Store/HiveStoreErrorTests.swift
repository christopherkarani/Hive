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

@Test("Store unknown channel throws unknownChannelID")
func testStore_UnknownChannel_Throws() throws {
    let registry = try HiveSchemaRegistry<StoreErrorSchema>()
    let cache = HiveInitialCache(registry: registry)
    let global = HiveGlobalStore(registry: registry, initialCache: cache)
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
    let global = HiveGlobalStore(registry: registry, initialCache: cache)
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
