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

@Test
func testSchemaVersion_GoldenHSV1() throws {
    let registry = try HiveSchemaRegistry<HSV1Schema>()
    let schemaVersion = HiveVersioning.schemaVersion(registry: registry)
    #expect(schemaVersion == "76a2aa861605de05dad8d5c61c87aa45b56fa74a32c5986397e5cf025866b892")
}

@Test
func testGraphVersion_GoldenHGV1() throws {
    var builder = HiveGraphBuilder<HGV1Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { input in
        HiveNodeOutput(writes: [], next: .end)
    }

    let compiled = try builder.compile()
    #expect(compiled.graphVersion == "6614009a9f5308c8dca81acf8ed7ee4e22a3d946e77a9eb864c70db09d1b993d")
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

