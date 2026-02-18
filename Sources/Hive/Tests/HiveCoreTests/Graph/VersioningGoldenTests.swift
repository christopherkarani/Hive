import Foundation
import Testing
@testable import HiveCore

private struct IntV1Codec: HiveCodec {
    let id: String = "int.v1"

    func encode(_ value: Int) throws -> Data {
        Data()
    }

    func decode(_ data: Data) throws -> Int {
        0
    }
}

private enum HSV1Schema: HiveSchema {
    enum Channels {
        static let a = HiveChannelKey<HSV1Schema, Int>(HiveChannelID("a"))
        static let b = HiveChannelKey<HSV1Schema, String>(HiveChannelID("b"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<HSV1Schema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.a,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { 0 },
                codec: HiveAnyCodec(IntV1Codec()),
                persistence: .checkpointed
            )
        ),
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.b,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { "" },
                codec: nil,
                persistence: .untracked
            )
        ),
    ]
}

private enum HGV1Schema: HiveSchema {
    static let channelSpecs: [AnyHiveChannelSpec<HGV1Schema>] = []
}

private enum HGV1MissingCodecSchema: HiveSchema {
    enum Channels {
        static let state = HiveChannelKey<HGV1MissingCodecSchema, Int>(HiveChannelID("state"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<HGV1MissingCodecSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.state,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { 0 },
                codec: nil,
                persistence: .checkpointed
            )
        )
    ]
}

private enum HSVTypeIntSchema: HiveSchema {
    enum Channels {
        static let shared = HiveChannelKey<HSVTypeIntSchema, Int>(HiveChannelID("shared"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<HSVTypeIntSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.shared,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { 0 },
                codec: nil,
                persistence: .untracked
            )
        )
    ]
}

private enum HSVTypeStringSchema: HiveSchema {
    enum Channels {
        static let shared = HiveChannelKey<HSVTypeStringSchema, String>(HiveChannelID("shared"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<HSVTypeStringSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.shared,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { "" },
                codec: nil,
                persistence: .untracked
            )
        )
    ]
}

@Test
func testSchemaVersion_GoldenHSV1() throws {
    let registry = try HiveSchemaRegistry<HSV1Schema>()
    let schemaVersion = HiveVersioning.schemaVersion(registry: registry)
    #expect(schemaVersion == "63cc06be45f8094342faf2a3f04088ed6646fdf4a8114cecbed5701eb06be3f6")
}

@Test
func testGraphVersion_GoldenHGV1() throws {
    var builder = HiveGraphBuilder<HGV1Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { input in
        HiveNodeOutput(writes: [], next: .end)
    }

    let compiled = try builder.compile()
    #expect(compiled.graphVersion == "9fea713f0fbb89802c76c07e4e508cacc159e94a901d44615f5430ad409d90da")
}

@Test
func testSchemaVersion_ChangesWhenChannelValueTypeChanges() throws {
    let intRegistry = try HiveSchemaRegistry<HSVTypeIntSchema>()
    let stringRegistry = try HiveSchemaRegistry<HSVTypeStringSchema>()

    let intVersion = HiveVersioning.schemaVersion(registry: intRegistry)
    let stringVersion = HiveVersioning.schemaVersion(registry: stringRegistry)

    #expect(intVersion != stringVersion)
}

@Test
func testGraphVersion_ChangesWhenRetryPolicyChanges() throws {
    let nodeID = HiveNodeID("A")

    var noRetry = HiveGraphBuilder<HGV1Schema>(start: [nodeID])
    noRetry.addNode(nodeID, retryPolicy: .none) { _ in
        HiveNodeOutput(writes: [], next: .end)
    }

    var retrying = HiveGraphBuilder<HGV1Schema>(start: [nodeID])
    retrying.addNode(
        nodeID,
        retryPolicy: .exponentialBackoff(
            initialNanoseconds: 1,
            factor: 2.0,
            maxAttempts: 3,
            maxNanoseconds: 10
        )
    ) { _ in
        HiveNodeOutput(writes: [], next: .end)
    }

    let noRetryCompiled = try noRetry.compile()
    let retryingCompiled = try retrying.compile()

    #expect(noRetryCompiled.graphVersion != retryingCompiled.graphVersion)
}

@Test
func testCompile_NodeIDReservedJoinCharacters_Fails() throws {
    var builder = HiveGraphBuilder<HGV1Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { input in HiveNodeOutput(writes: [], next: .end) }

    let badID = HiveNodeID("bad:node")
    builder.addNode(badID) { input in HiveNodeOutput(writes: [], next: .end) }

    do {
        _ = try builder.compile()
        #expect(Bool(false))
    } catch let error as HiveCompilationError {
        switch error {
        case .invalidNodeIDContainsReservedJoinCharacters(let nodeID):
            #expect(nodeID == badID)
        default:
            #expect(Bool(false))
        }
    }
}

@Test
func testCompile_MissingRequiredCodec_Fails() throws {
    var builder = HiveGraphBuilder<HGV1MissingCodecSchema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(next: .end)
    }

    do {
        _ = try builder.compile()
        #expect(Bool(false))
    } catch let error as HiveCompilationError {
        switch error {
        case .missingRequiredCodec(let channelID):
            #expect(channelID == HGV1MissingCodecSchema.Channels.state.id)
        default:
            #expect(Bool(false))
        }
    }
}
