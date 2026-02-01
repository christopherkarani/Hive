import Testing
@testable import HiveCore

private final class InitialEvalLog: @unchecked Sendable {
    private(set) var order: [String] = []
    private(set) var counts: [String: Int] = [:]

    func record(_ id: String) {
        order.append(id)
        counts[id, default: 0] += 1
    }
}

private enum InitialCacheSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<InitialCacheSchema>] { [] }
}

@Test("initialCache evaluated once in lexicographic order")
func testInitialCache_EvaluatedOnceInLexOrder() throws {
    let log = InitialEvalLog()
    let reducer = HiveReducer<Int> { current, update in current + update }

    let keyB = HiveChannelKey<InitialCacheSchema, Int>(HiveChannelID("b"))
    let keyA = HiveChannelKey<InitialCacheSchema, Int>(HiveChannelID("a"))
    let keyAA = HiveChannelKey<InitialCacheSchema, Int>(HiveChannelID("aa"))
    let keyC = HiveChannelKey<InitialCacheSchema, Int>(HiveChannelID("c"))

    let specB = HiveChannelSpec(
        key: keyB,
        scope: .global,
        reducer: reducer,
        initial: { log.record("b"); return 2 },
        persistence: .checkpointed
    )
    let specA = HiveChannelSpec(
        key: keyA,
        scope: .global,
        reducer: reducer,
        initial: { log.record("a"); return 1 },
        persistence: .checkpointed
    )
    let specAA = HiveChannelSpec(
        key: keyAA,
        scope: .taskLocal,
        reducer: reducer,
        initial: { log.record("aa"); return 11 },
        persistence: .checkpointed
    )
    let specC = HiveChannelSpec(
        key: keyC,
        scope: .global,
        reducer: reducer,
        initial: { log.record("c"); return 3 },
        persistence: .checkpointed
    )

    let registry = try HiveSchemaRegistry<InitialCacheSchema>(
        channelSpecs: [
            AnyHiveChannelSpec(specB),
            AnyHiveChannelSpec(specA),
            AnyHiveChannelSpec(specAA),
            AnyHiveChannelSpec(specC)
        ]
    )

    _ = HiveInitialCache(registry: registry)

    #expect(log.order == ["a", "aa", "b", "c"])
    #expect(log.counts["a"] == 1)
    #expect(log.counts["aa"] == 1)
    #expect(log.counts["b"] == 1)
    #expect(log.counts["c"] == 1)
}
