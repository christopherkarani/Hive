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

@Test("HiveCheckpointWaxStore.loadLatest breaks ties by newest frame")
func hiveCheckpointWaxStoreLoadLatestPrefersNewestFrameOnStepTie() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url, walSize: 4 * 1024 * 1024)

    let threadID = HiveThreadID("thread-1")
    let stepIndex = 1

    let older = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("zzz"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        stepIndex: stepIndex,
        schemaVersion: "schema",
        graphVersion: "graph",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )

    let newer = HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID("aaa"),
        threadID: threadID,
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        stepIndex: stepIndex,
        schemaVersion: "schema",
        graphVersion: "graph",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )

    try await store.save(older)
    try await store.save(newer)

    let loaded = try await store.loadLatest(threadID: threadID)
    #expect(loaded?.id.rawValue == "aaa")
}
