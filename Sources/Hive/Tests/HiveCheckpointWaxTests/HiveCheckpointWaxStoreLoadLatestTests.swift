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

private func makeCheckpoint(
    id: String,
    threadID: HiveThreadID,
    runID: UUID,
    stepIndex: Int
) -> HiveCheckpoint<TestSchema> {
    HiveCheckpoint<TestSchema>(
        id: HiveCheckpointID(id),
        threadID: threadID,
        runID: HiveRunID(runID),
        stepIndex: stepIndex,
        schemaVersion: "schema",
        graphVersion: "graph",
        globalDataByChannelID: [:],
        frontier: [],
        joinBarrierSeenByJoinID: [:],
        interruption: nil
    )
}

@Test("HiveCheckpointWaxStore.loadLatest breaks ties by newest frame")
func hiveCheckpointWaxStoreLoadLatestPrefersNewestFrameOnStepTie() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url, walSize: 4 * 1024 * 1024)

    let threadID = HiveThreadID("thread-1")
    let stepIndex = 1

    let older = makeCheckpoint(
        id: "zzz",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        stepIndex: stepIndex
    )

    let newer = makeCheckpoint(
        id: "aaa",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        stepIndex: stepIndex
    )

    try await store.save(older)
    try await store.save(newer)

    let loaded = try await store.loadLatest(threadID: threadID)
    #expect(loaded?.id.rawValue == "aaa")
}

@Test("HiveCheckpointWaxStore.loadLatest returns nil for empty store and unknown thread")
func hiveCheckpointWaxStoreLoadLatestReturnsNilWhenNoCheckpointExists() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)

    let loaded = try await store.loadLatest(threadID: HiveThreadID("missing-thread"))
    #expect(loaded == nil)
}

@Test("HiveCheckpointWaxStore.loadLatest reads a checkpoint after save")
func hiveCheckpointWaxStoreLoadLatestReadsSavedCheckpoint() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)
    let threadID = HiveThreadID("thread-pending")

    let checkpoint = makeCheckpoint(
        id: "pending-checkpoint",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
        stepIndex: 1
    )

    try await store.save(checkpoint)
    let loaded = try await store.loadLatest(threadID: threadID)
    #expect(loaded?.id.rawValue == "pending-checkpoint")
}

@Test("HiveCheckpointWaxStore.loadLatest prefers highest step index across runs")
func hiveCheckpointWaxStoreLoadLatestPrefersHighestStepAcrossRuns() async throws {
    let url = try makeTempWaxURL()
    let store = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)
    let threadID = HiveThreadID("thread-cross-run")

    let olderRunHigherStep = makeCheckpoint(
        id: "older-run-higher-step",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        stepIndex: 9
    )
    let newerRunLowerStep = makeCheckpoint(
        id: "newer-run-lower-step",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        stepIndex: 1
    )

    try await store.save(olderRunHigherStep)
    try await store.save(newerRunLowerStep)

    let loaded = try await store.loadLatest(threadID: threadID)
    #expect(loaded?.id.rawValue == "older-run-higher-step")
}

@Test("HiveCheckpointWaxStore.loadLatest persists across close and reopen")
func hiveCheckpointWaxStoreLoadLatestPersistsAcrossReopen() async throws {
    let url = try makeTempWaxURL()
    let threadID = HiveThreadID("thread-reopen")
    let expected = makeCheckpoint(
        id: "persisted-checkpoint",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
        stepIndex: 3
    )

    do {
        let initialStore = try await HiveCheckpointWaxStore<TestSchema>.create(at: url)
        try await initialStore.save(expected)
    }

    let reopenedStore = try await HiveCheckpointWaxStore<TestSchema>.open(at: url)
    let loaded = try await reopenedStore.loadLatest(threadID: threadID)
    #expect(loaded?.id.rawValue == expected.id.rawValue)
    #expect(loaded?.runID.rawValue == expected.runID.rawValue)
    #expect(loaded?.stepIndex == expected.stepIndex)
}
