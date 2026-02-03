import Foundation
import Testing
import HiveCheckpointWax

private enum TestSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
}

private func makeTempWaxURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-checkpointwax-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("wax.wax")
}

@Test("HiveCheckpointWaxStore.listCheckpoints orders by stepIndex desc then newest frame")
func hiveCheckpointWaxStoreListCheckpointsOrdering() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)

    let threadID = HiveThreadID("thread-1")

    let checkpoint1 = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("a1"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        stepIndex: 1,
        schemaVersion: "schema-1",
        graphVersion: "graph-1",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
    let checkpoint2 = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("a2"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        stepIndex: 2,
        schemaVersion: "schema-2",
        graphVersion: "graph-2",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
    let checkpoint3 = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("a3"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
        stepIndex: 2,
        schemaVersion: "schema-3",
        graphVersion: "graph-3",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )

    try await store.save(checkpoint1)
    try await store.save(checkpoint2)
    try await store.save(checkpoint3)

    let summaries = try await store.listCheckpoints(threadID: threadID, limit: nil)
    #expect(summaries.map(\.id.rawValue) == ["a3", "a2", "a1"])
    #expect(summaries.map(\.stepIndex) == [2, 2, 1])

    #expect(summaries[0].schemaVersion == "schema-3")
    #expect(summaries[0].graphVersion == "graph-3")

    let limited = try await store.listCheckpoints(threadID: threadID, limit: 2)
    #expect(limited.map(\.id.rawValue) == ["a3", "a2"])
}

@Test("HiveCheckpointWaxStore.loadCheckpoint returns payload for matching ID")
func hiveCheckpointWaxStoreLoadCheckpointByID() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)

    let threadID = HiveThreadID("thread-1")
    let checkpoint = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("needle"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000010")!),
        stepIndex: 7,
        schemaVersion: "schema",
        graphVersion: "graph",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
    try await store.save(checkpoint)

    let loaded = try await store.loadCheckpoint(threadID: threadID, id: HiveCheckpointID("needle"))
    #expect(loaded?.stepIndex == 7)
    #expect(loaded?.runID.rawValue.uuidString.lowercased() == "00000000-0000-0000-0000-000000000010")

    let missing = try await store.loadCheckpoint(threadID: threadID, id: HiveCheckpointID("missing"))
    #expect(missing == nil)
}

