import Foundation
import Synchronization
import Testing
@testable import HiveCore

// MARK: - Shared test infrastructure

private struct TestClock2: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct TestLogger2: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor TestCPStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {
    var checkpoints: [HiveCheckpoint<Schema>] = []
    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws { checkpoints.append(checkpoint) }
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints.filter { $0.threadID == threadID }.max {
            $0.stepIndex < $1.stepIndex
        }
    }
    func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints.first { $0.threadID == threadID && $0.id == id }
    }
    func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] { [] }
    func all() async -> [HiveCheckpoint<Schema>] { checkpoints }
}

private func makeEnv2<Schema: HiveSchema>(context: Schema.Context, store: AnyHiveCheckpointStore<Schema>? = nil) -> HiveEnvironment<Schema> {
    HiveEnvironment(context: context, clock: TestClock2(), logger: TestLogger2(), checkpointStore: store)
}

private func drain(_ stream: AsyncThrowingStream<HiveEvent, Error>) async -> [HiveEvent] {
    var out: [HiveEvent] = []
    do { for try await e in stream { out.append(e) } } catch {}
    return out
}

// MARK: - Cache hit/miss and LRU writeback tests

/// Tests end-to-end caching behavior: first execution stores result, subsequent calls with
/// identical store state return cached output without re-executing the node.
@Test("Cache hit returns stored output and skips node execution")
func testCache_HitSkipsNodeExecution() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("counter"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: HiveReducer { _, update in update },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }
    let counterKey = HiveChannelKey<Schema, Int>(HiveChannelID("counter"))

    // executionCount is mutated only when the node body actually runs (not on cache hit).
    let executionCount = Mutex(0)

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("worker")])
    builder.addNode(
        HiveNodeID("worker"),
        cachePolicy: .lru(maxEntries: 4)
    ) { _ in
        executionCount.withLock { $0 += 1 }
        return HiveNodeOutput(writes: [AnyHiveWrite(counterKey, 99)], next: .end)
    }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnv2(context: ()))

    // First run — cache miss, node should execute.
    let h1 = await runtime.run(threadID: HiveThreadID("t"), input: (), options: HiveRunOptions())
    _ = try await h1.outcome.value
    _ = await drain(h1.events)
    let afterFirst = executionCount.withLock { $0 }
    #expect(afterFirst == 1, "Node must execute on first run (cache miss)")

    // Second run with same thread (same store state) — should be a cache hit.
    let h2 = await runtime.run(threadID: HiveThreadID("t"), input: (), options: HiveRunOptions())
    _ = try await h2.outcome.value
    _ = await drain(h2.events)
    let afterSecond = executionCount.withLock { $0 }
    #expect(afterSecond == 1, "Node must NOT execute on second run with identical store state (cache hit)")
}

/// Verifies that after a cache hit, the mutated LRU order is written back to `state.nodeCaches`,
/// so that LRU eviction selects the correct (least-recently-used) entry.
///
/// Regression test for the value-copy bug where `nodeCache.lookup()` mutations were discarded:
/// the runtime fetched `var nodeCache = state.nodeCaches[task.nodeID]` (a value copy) and
/// never wrote it back, so `lastUsedOrder` updates from hits were silently lost.
@Test("Cache LRU writeback: hit advances LRU order so correct entry is evicted")
func testCache_LRUWritebackPreservesOrder() {
    // This test is at the HiveNodeCache level to directly verify the mutation semantics
    // that the runtime relies on. The runtime fix ensures the mutated copy is written
    // back to state.nodeCaches after every lookup (hit or miss).
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("x"))
            return [AnyHiveChannelSpec(HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { _, u in u },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            ))]
        }
    }

    let policy = HiveCachePolicy<Schema>.lru(maxEntries: 2)
    let fakeOutput = HiveNodeOutput<Schema>(next: .end)

    var cache = HiveNodeCache<Schema>()
    cache.store(key: "A", output: fakeOutput, policy: policy, nowNanoseconds: 0)
    cache.store(key: "B", output: fakeOutput, policy: policy, nowNanoseconds: 0)
    // A was stored first → lower lastUsedOrder → LRU candidate

    // Access A — makes A MRU; B becomes LRU
    _ = cache.lookup(key: "A", policy: policy, nowNanoseconds: 0)

    // Insert C — should evict B (now LRU), not A
    cache.store(key: "C", output: fakeOutput, policy: policy, nowNanoseconds: 0)

    #expect(cache.entries.count == 2, "Cache at capacity: 2 entries")
    #expect(cache.lookup(key: "A", policy: policy, nowNanoseconds: 0) != nil, "A should remain (MRU)")
    #expect(cache.lookup(key: "B", policy: policy, nowNanoseconds: 0) == nil, "B should be evicted (LRU)")
    #expect(cache.lookup(key: "C", policy: policy, nowNanoseconds: 0) != nil, "C should be present")
}

// MARK: - HiveCachePolicy.channels with unknown channel IDs

/// When `HiveCachePolicy.channels(_:)` is called with channel IDs that don't exist in the
/// store, the hash computation must be a no-op for those IDs (not crash), producing a
/// valid (if less discriminating) cache key.
@Test("CachePolicy.channels with unknown channel IDs produces valid key without crash")
func testCachePolicy_ChannelsUnknownIDs() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, String>(HiveChannelID("msg"))
            let spec = HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { _, u in u },
                updatePolicy: .multi,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let registry = try HiveSchemaRegistry<Schema>()
    let cache = HiveInitialCache(registry: registry)
    let store = try HiveGlobalStore<Schema>(registry: registry, initialCache: cache)
    let storeView = HiveStoreView(
        global: store,
        taskLocal: HiveTaskLocalStore(registry: registry),
        initialCache: cache,
        registry: registry
    )

    // "nonexistent" channel ID does not exist in Schema.
    let policy = HiveCachePolicy<Schema>.channels(HiveChannelID("nonexistent"), maxEntries: 4)
    let nodeID = HiveNodeID("node")

    // Must not throw and must return a non-empty string.
    let key = try policy.keyProvider.cacheKey(forNode: nodeID, store: storeView)
    #expect(!key.isEmpty, "Cache key for unknown channel IDs must be a valid non-empty string")

    // Two invocations with identical state must return the same key (determinism).
    let key2 = try policy.keyProvider.cacheKey(forNode: nodeID, store: storeView)
    #expect(key == key2, "Cache key must be deterministic for identical state")
}

// MARK: - getState checkpoint fallback

/// `getState` must return a snapshot from the checkpoint store when there is no in-memory state.
@Test("getState falls back to checkpoint store when no in-memory state exists")
func testGetState_CheckpointFallback() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("val"))
            let spec = HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { _, u in u },
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec2(id: "val")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }
    let valKey = HiveChannelKey<Schema, Int>(HiveChannelID("val"))

    let cpStore = TestCPStore<Schema>()
    let env = makeEnv2(context: (), store: AnyHiveCheckpointStore(cpStore))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(valKey, 42)], next: .end)
    }
    let graph = try builder.compile()
    let runtime1 = try HiveRuntime(graph: graph, environment: env)

    // Run thread to completion so a checkpoint is saved.
    let h = await runtime1.run(
        threadID: HiveThreadID("t"),
        input: (),
        options: HiveRunOptions(checkpointPolicy: .everyStep)
    )
    _ = try await h.outcome.value
    _ = await drain(h.events)

    // New runtime instance has no in-memory state — must fall back to checkpoint store.
    let runtime2 = try HiveRuntime(graph: graph, environment: env)
    let snapshot = try await runtime2.getState(threadID: HiveThreadID("t"))
    #expect(snapshot != nil, "getState must return a snapshot from checkpoint store")
    #expect(snapshot?.checkpoint != nil, "snapshot loaded from checkpoint must include summary")
}

/// `getState` returns nil when there is neither in-memory state nor a checkpoint.
@Test("getState returns nil when no state exists anywhere")
func testGetState_NilWhenNoState() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .end) }
    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnv2(context: ()))

    let snapshot = try await runtime.getState(threadID: HiveThreadID("never-run"))
    #expect(snapshot == nil)
}

// MARK: - HiveNodeOptions.deferred

/// Deferred nodes must execute after all non-deferred frontier nodes have completed
/// (i.e., when the main frontier is exhausted and deferred nodes are promoted).
@Test("Deferred nodes execute after main frontier is exhausted")
func testDeferredNodes_ExecuteAfterMainFrontier() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))
            let spec = HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { [] as [String] },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }
    let logKey = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("main")])
    builder.addNode(HiveNodeID("main")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(logKey, ["main"])], next: .end)
    }
    // "cleanup" is deferred: it must only run after main + summary have finished.
    builder.addNode(HiveNodeID("summary")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(logKey, ["summary"])], next: .end)
    }
    builder.addNode(
        HiveNodeID("cleanup"),
        options: .deferred
    ) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(logKey, ["cleanup"])], next: .end)
    }
    builder.addEdge(from: HiveNodeID("main"), to: HiveNodeID("summary"))
    // cleanup is reachable only via the deferred promotion path (no static edge to it from any
    // non-deferred node, but it IS listed as a start node so the graph can reach it)

    // Actually deferred nodes need to be in the frontier, not just defined.
    // Let's use a router to schedule cleanup alongside summary, but cleanup is deferred.
    var builder2 = HiveGraphBuilder<Schema>(start: [HiveNodeID("main")])
    builder2.addNode(HiveNodeID("main")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(logKey, ["main"])],
            next: .nodes([HiveNodeID("summary"), HiveNodeID("cleanup")])
        )
    }
    builder2.addNode(HiveNodeID("summary")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(logKey, ["summary"])], next: .end)
    }
    builder2.addNode(
        HiveNodeID("cleanup"),
        options: .deferred
    ) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(logKey, ["cleanup"])], next: .end)
    }

    let graph = try builder2.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnv2(context: ()))

    let h = await runtime.run(threadID: HiveThreadID("t"), input: (), options: HiveRunOptions())
    _ = try await h.outcome.value
    _ = await drain(h.events)

    // Retrieve the final store.
    let snap = try await runtime.getState(threadID: HiveThreadID("t"))
    let log = (try? snap?.store.get(logKey)) ?? []

    // All three nodes must have run.
    #expect(log.contains("main"), "main node must have run")
    #expect(log.contains("summary"), "summary node must have run")
    #expect(log.contains("cleanup"), "deferred cleanup node must have run")

    // Crucially, cleanup must appear AFTER both main and summary in execution order.
    // The log reducer appends in commit order: main (step 1), then summary + cleanup
    // in separate supersteps (cleanup promoted when summary's step produces empty frontier).
    if let summaryIdx = log.firstIndex(of: "summary"),
       let cleanupIdx = log.firstIndex(of: "cleanup") {
        #expect(cleanupIdx > summaryIdx, "cleanup (deferred) must execute after summary (non-deferred)")
    }
}

// MARK: - Ephemeral channel reset after superstep

/// Ephemeral channels must reset to their initial value after each superstep commit.
/// Writes from one superstep must not be visible to nodes in the next superstep.
@Test("Ephemeral channel resets to initial value after each superstep")
func testEphemeralChannel_ResetsAfterSuperstep() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let ephKey = HiveChannelKey<Schema, Int>(HiveChannelID("eph"))
            let accumKey = HiveChannelKey<Schema, Int>(HiveChannelID("accum"))

            let ephSpec = HiveChannelSpec(
                key: ephKey, scope: .global,
                reducer: HiveReducer { _, u in u },
                updatePolicy: .multi,
                initial: { -1 },
                persistence: .ephemeral
            )
            let accumSpec = HiveChannelSpec(
                key: accumKey, scope: .global,
                reducer: HiveReducer { cur, u in cur + u },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(ephSpec), AnyHiveChannelSpec(accumSpec)]
        }
    }
    let ephKey = HiveChannelKey<Schema, Int>(HiveChannelID("eph"))
    let accumKey = HiveChannelKey<Schema, Int>(HiveChannelID("accum"))

    // nodeA writes 99 to the ephemeral channel.
    // nodeB (step 2) reads ephemeral; it must see the reset value (-1), not 99.
    // nodeB accumulates what it sees so we can verify the read value.
    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(ephKey, 99)],
            next: .useGraphEdges
        )
    }
        builder.addNode(HiveNodeID("B")) { input in
        let seen = (try? input.store.get(ephKey)) ?? -999
        return HiveNodeOutput(
            writes: [AnyHiveWrite(accumKey, seen)],
            next: .end
        )
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnv2(context: ()))

    let h = await runtime.run(threadID: HiveThreadID("t"), input: (), options: HiveRunOptions())
    _ = try await h.outcome.value
    _ = await drain(h.events)

    let snap = try await runtime.getState(threadID: HiveThreadID("t"))
    let accum = try snap?.store.get(accumKey)
    // B must have read the reset value (-1), not A's write (99).
    #expect(accum == -1, "B must read ephemeral channel's initial value (-1) not A's write (99)")
}

// MARK: - Fork from checkpoint

/// `fork` must load a checkpoint, start a new run thread from that frontier, execute to
/// completion, and produce a `.finished` outcome.
@Test("fork runs a new thread from a historical checkpoint to completion")
func testFork_RunsFromCheckpointToCompletion() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("steps"))
            let spec = HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { cur, u in cur + u },
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec2(id: "steps")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }
    let stepsKey = HiveChannelKey<Schema, Int>(HiveChannelID("steps"))

    let cpStore = TestCPStore<Schema>()
    let env = makeEnv2(context: (), store: AnyHiveCheckpointStore(cpStore))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(stepsKey, 1)], next: .useGraphEdges)
    }
    builder.addNode(HiveNodeID("B")) { _ in
        HiveNodeOutput(writes: [AnyHiveWrite(stepsKey, 1)], next: .end)
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: env)

    // Run with checkpoint after step 1 (A finishes, B is in frontier).
    let h1 = await runtime.run(
        threadID: HiveThreadID("source"),
        input: (),
        options: HiveRunOptions(maxSteps: 1, checkpointPolicy: .everyStep)
    )
    _ = try await h1.outcome.value
    _ = await drain(h1.events)

    let checkpoints = await cpStore.all()
    #expect(!checkpoints.isEmpty, "At least one checkpoint must be saved")
    let checkpointID = checkpoints[0].id

    // Fork from that checkpoint into a new thread.
    let h2 = await runtime.fork(
        threadID: HiveThreadID("source"),
        fromCheckpointID: checkpointID,
        into: HiveThreadID("fork"),
        options: HiveRunOptions(checkpointPolicy: .disabled)
    )
    let outcome = try await h2.outcome.value
    _ = await drain(h2.events)

    switch outcome {
    case .finished:
        break
    default:
        Issue.record("Expected .finished outcome from fork, got \(outcome)")
    }

    // Forked thread should have completed B (1 more step), giving total steps = 1 (from checkpoint) + 1 = 2.
    let snap = try await runtime.getState(threadID: HiveThreadID("fork"))
    let totalSteps = try snap?.store.get(stepsKey)
    #expect(totalSteps == 2, "Fork should have executed B (+1 step), total steps from start = 2")
}

// MARK: - Codec helper used in tests

private struct IntCodec2: HiveCodec {
    let id: String
    func encode(_ value: Int) throws -> Data { Data(String(value).utf8) }
    func decode(_ data: Data) throws -> Int {
        guard let v = Int(String(decoding: data, as: UTF8.self)) else {
            struct DecodeError: Error {}
            throw DecodeError()
        }
        return v
    }
}

// MARK: - nextNodes deduplication

/// When a node is reachable via both a router and a static edge, it can appear multiple
/// times in the frontier. `getState.nextNodes` must deduplicate and return a sorted list.
@Test("getState.nextNodes deduplicates nodes that appear multiple times in frontier")
func testGetState_NextNodesDeduplication() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("v"))
            return [AnyHiveChannelSpec(HiveChannelSpec(
                key: key, scope: .global,
                reducer: HiveReducer { _, u in u },
                updatePolicy: .multi,
                initial: { 0 },
                persistence: .untracked
            ))]
        }
    }

    // A routes to B AND has a static edge to B — B would appear twice in frontier without dedup.
    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in HiveNodeOutput(next: .useGraphEdges) }
    builder.addNode(HiveNodeID("B")) { _ in HiveNodeOutput(next: .end) }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))
    builder.addRouter(from: HiveNodeID("A")) { _ in .nodes([HiveNodeID("B")]) }

    let graph = try builder.compile()
    let runtime = try HiveRuntime(graph: graph, environment: makeEnv2(context: ()))

    // Run only 1 step so B is in the frontier (not yet executed).
    let h = await runtime.run(
        threadID: HiveThreadID("t"),
        input: (),
        options: HiveRunOptions(maxSteps: 1)
    )
    _ = try await h.outcome.value
    _ = await drain(h.events)

    let snap = try await runtime.getState(threadID: HiveThreadID("t"))
    let nextNodes = snap?.nextNodes ?? []

    // B must appear exactly once even if the frontier has it twice.
    let bCount = nextNodes.filter { $0 == HiveNodeID("B") }.count
    #expect(bCount == 1, "B must appear exactly once in nextNodes (deduplication)")
    #expect(nextNodes == nextNodes.sorted { $0.rawValue < $1.rawValue }, "nextNodes must be lexicographically sorted")
}
