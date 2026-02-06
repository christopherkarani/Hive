import Foundation
import Testing
import HiveCheckpointWax
import Wax

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
    let wax = try await Wax.create(at: url)
    let store = HiveCheckpointWaxStore<TestSchema>(wax: wax)

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
    do {
        try await store.save(older)
        try await store.save(newer)

        let loaded = try await store.loadLatest(threadID: threadID)
        #expect(loaded?.id.rawValue == "aaa")
        try await wax.close()
    } catch {
        try? await wax.close()
        throw error
    }
}

@Test("HiveCheckpointWaxStore.loadLatest returns nil for empty store and unknown thread")
func hiveCheckpointWaxStoreLoadLatestReturnsNilWhenNoCheckpointExists() async throws {
    let url = try makeTempWaxURL()
    let wax = try await Wax.create(at: url)
    let store = HiveCheckpointWaxStore<TestSchema>(wax: wax)

    do {
        let loaded = try await store.loadLatest(threadID: HiveThreadID("missing-thread"))
        #expect(loaded == nil)
        try await wax.close()
    } catch {
        try? await wax.close()
        throw error
    }
}

@Test("HiveCheckpointWaxStore.loadLatest can read pending checkpoint before flush")
func hiveCheckpointWaxStoreLoadLatestSeesPendingCheckpointBeforeFlush() async throws {
    let url = try makeTempWaxURL()
    let wax = try await Wax.create(at: url)
    let store = HiveCheckpointWaxStore<TestSchema>(wax: wax)
    let threadID = HiveThreadID("thread-pending")

    let checkpoint = makeCheckpoint(
        id: "pending-checkpoint",
        threadID: threadID,
        runID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
        stepIndex: 1
    )

    do {
        try await store.save(checkpoint, commit: false)
        let loaded = try await store.loadLatest(threadID: threadID)
        #expect(loaded?.id.rawValue == "pending-checkpoint")
        try await wax.close()
    } catch {
        try? await wax.close()
        throw error
    }
}

@Test("HiveCheckpointWaxStore.loadLatest prefers most recently written checkpoint across runs")
func hiveCheckpointWaxStoreLoadLatestPrefersNewestWriteAcrossRuns() async throws {
    let url = try makeTempWaxURL()
    let wax = try await Wax.create(at: url)
    let store = HiveCheckpointWaxStore<TestSchema>(wax: wax)
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

    do {
        try await store.save(olderRunHigherStep)
        try await store.save(newerRunLowerStep)

        let loaded = try await store.loadLatest(threadID: threadID)
        #expect(loaded?.id.rawValue == "newer-run-lower-step")
        try await wax.close()
    } catch {
        try? await wax.close()
        throw error
    }
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

    let initialWax = try await Wax.create(at: url)
    let initialStore = HiveCheckpointWaxStore<TestSchema>(wax: initialWax)
    do {
        try await initialStore.save(expected)
        try await initialWax.close()
    } catch {
        try? await initialWax.close()
        throw error
    }

    let reopenedWax = try await Wax.open(at: url)
    let reopenedStore = HiveCheckpointWaxStore<TestSchema>(wax: reopenedWax)
    do {
        let loaded = try await reopenedStore.loadLatest(threadID: threadID)
        #expect(loaded?.id.rawValue == expected.id.rawValue)
        #expect(loaded?.runID.rawValue == expected.runID.rawValue)
        #expect(loaded?.stepIndex == expected.stepIndex)
        try await reopenedWax.close()
    } catch {
        try? await reopenedWax.close()
        throw error
    }
}
