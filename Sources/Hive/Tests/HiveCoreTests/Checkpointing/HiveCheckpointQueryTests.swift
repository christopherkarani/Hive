import Foundation
import Testing
@testable import HiveCore

private enum TestSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
}

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor NonQueryableStore: HiveCheckpointStore {
    typealias Schema = TestSchema

    func save(_ checkpoint: HiveCheckpoint<TestSchema>) async throws {}
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<TestSchema>? { nil }
}

private actor QueryableStore: HiveCheckpointQueryableStore {
    typealias Schema = TestSchema

    let summary = HiveCheckpointSummary(
        id: HiveCheckpointID("cp-1"),
        threadID: HiveThreadID("thread-1"),
        runID: HiveRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        stepIndex: 7
    )

    func save(_ checkpoint: HiveCheckpoint<TestSchema>) async throws {}
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<TestSchema>? { nil }

    func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] {
        [summary]
    }

    func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<TestSchema>? {
        HiveCheckpoint(
            id: id,
            threadID: threadID,
            runID: summary.runID,
            stepIndex: summary.stepIndex,
            schemaVersion: "schema",
            graphVersion: "graph",
            globalDataByChannelID: [:],
            frontier: [],
            joinBarrierSeenByJoinID: [:],
            interruption: nil
        )
    }
}

@Test("AnyHiveCheckpointStore throws unsupported for query calls when store lacks capability")
func anyHiveCheckpointStoreUnsupportedQueryThrows() async throws {
    let store = AnyHiveCheckpointStore<TestSchema>(NonQueryableStore())
    do {
        _ = try await store.listCheckpoints(threadID: HiveThreadID("thread-1"), limit: nil)
        #expect(Bool(false))
    } catch let error as HiveCheckpointQueryError {
        switch error {
        case .unsupported:
            #expect(Bool(true))
        }
    }
}

@Test("AnyHiveCheckpointStore forwards query calls when store supports capability")
func anyHiveCheckpointStoreForwardsQueries() async throws {
    let store = AnyHiveCheckpointStore<TestSchema>(QueryableStore())
    let summaries = try await store.listCheckpoints(threadID: HiveThreadID("thread-1"), limit: nil)
    #expect(summaries.map(\.id.rawValue) == ["cp-1"])

    let loaded = try await store.loadCheckpoint(threadID: HiveThreadID("thread-1"), id: HiveCheckpointID("cp-1"))
    #expect(loaded?.stepIndex == 7)
}

@Test("HiveRuntime checkpoint query helpers throw when no store is configured")
func hiveRuntimeCheckpointQueryHelpersRequireStore() async throws {
    var builder = HiveGraphBuilder<TestSchema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(writes: [], next: .end) }
    let graph = try builder.compile()

    let runtime = HiveRuntime(
        graph: graph,
        environment: HiveEnvironment(
            context: (),
            clock: NoopClock(),
            logger: NoopLogger(),
            checkpointStore: nil
        )
    )

    do {
        _ = try await runtime.getCheckpointHistory(threadID: HiveThreadID("thread-1"), limit: nil)
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .checkpointStoreMissing:
            #expect(Bool(true))
        default:
            #expect(Bool(false))
        }
    }
}

@Test("HiveRuntime checkpoint query helpers forward when store supports capability")
func hiveRuntimeCheckpointQueryHelpersForward() async throws {
    var builder = HiveGraphBuilder<TestSchema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(writes: [], next: .end) }
    let graph = try builder.compile()

    let store = AnyHiveCheckpointStore<TestSchema>(QueryableStore())
    let runtime = HiveRuntime(
        graph: graph,
        environment: HiveEnvironment(
            context: (),
            clock: NoopClock(),
            logger: NoopLogger(),
            checkpointStore: store
        )
    )

    let summaries = try await runtime.getCheckpointHistory(threadID: HiveThreadID("thread-1"), limit: nil)
    #expect(summaries.map(\.id.rawValue) == ["cp-1"])

    let loaded = try await runtime.getCheckpoint(threadID: HiveThreadID("thread-1"), id: HiveCheckpointID("cp-1"))
    #expect(loaded?.stepIndex == 7)
}

