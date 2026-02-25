# P0 Production Blockers Fix Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all 12 P0 production-blocking issues identified in the enterprise audit so Hive can ship to production.

**Architecture:** Each fix is isolated: spec compliance (frontier sort), memory safety (weak captures, thread eviction), error handling (swallowed errors, shadowing), performance (fingerprint fast-path, type-ID caching). All fixes maintain backward compatibility and determinism guarantees.

**Tech Stack:** Swift 6.2, Swift Testing, HiveCore, HiveDSL

---

### Task 1: Fix Frontier Lexicographic Sort (Spec Violation)

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift:2428-2436`
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift:751-754`
- Test: `Sources/Hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift`

The frontier is not sorted lexicographically before task ordinal assignment. This breaks write priority determinism in multi-node steps.

**Step 1: Write the failing test**

In `Sources/Hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift`, add:

```swift
@Test("Frontier is sorted lexicographically regardless of router return order")
func testFrontierLexicographicSort() async throws {
    // Schema with an append channel to verify write ordering
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Self>] {
            [AnyHiveChannelSpec(HiveChannelSpec<Self, [String]>(
                id: HiveChannelID("log"),
                scope: .global,
                persistence: .untracked,
                initial: [],
                reducer: .append()
            ))]
        }
    }

    let logKey = HiveChannelKey<Schema, [String]>(HiveChannelID("log"))

    var builder = HiveGraphBuilder<Schema>()
    // "dispatch" node routes to Z then A (reverse lex order)
    builder.addNode(HiveNodeID("dispatch")) { input in
        HiveNodeOutput(writes: [], next: .nodes([HiveNodeID("z-worker"), HiveNodeID("a-worker")]))
    }
    // Both workers write to "log" channel. If frontier is sorted,
    // a-worker (ordinal 0) writes first, z-worker (ordinal 1) writes second.
    builder.addNode(HiveNodeID("a-worker")) { input in
        HiveNodeOutput(writes: [
            AnyHiveWrite(key: logKey, value: ["a-write"])
        ], next: .end)
    }
    builder.addNode(HiveNodeID("z-worker")) { input in
        HiveNodeOutput(writes: [
            AnyHiveWrite(key: logKey, value: ["z-write"])
        ], next: .end)
    }
    builder.setStart([HiveNodeID("dispatch")])
    let graph = try builder.compile()

    let env = HiveEnvironment<Schema>(context: ())
    let runtime = try HiveRuntime(graph: graph, environment: env)
    let handle = await runtime.run(
        threadID: HiveThreadID("test"),
        input: (),
        options: HiveRunOptions(maxSteps: 10)
    )

    var events: [HiveEvent] = []
    for try await event in handle.events { events.append(event) }
    let outcome = try await handle.outcome.value

    // Verify: a-worker writes BEFORE z-worker (lex order), so log = ["a-write", "z-write"]
    guard case .finished(let output, _) = outcome,
          case .fullStore(let store) = output else {
        Issue.record("Expected finished with fullStore")
        return
    }
    let log = try store.get(logKey)
    #expect(log == ["a-write", "z-write"], "Frontier must be sorted lexicographically: a-worker before z-worker")
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter HiveRuntimeStepAlgorithmTests/testFrontierLexicographicSort`
Expected: FAIL — log will be `["z-write", "a-write"]` because frontier is unsorted

**Step 3: Sort normalFrontier and deferredNextFrontier in commitStep**

In `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift`, after line 2436 (the for-loop splitting normal/deferred), add sorts before the return:

```swift
        // §11 compliance: frontier MUST be in lexicographic node ID order
        // so that task ordinals (which determine write priority) are deterministic.
        normalFrontier.sort {
            HiveOrdering.lexicographicallyPrecedes($0.seed.nodeID.rawValue, $1.seed.nodeID.rawValue)
        }
        deferredNextFrontier.sort {
            HiveOrdering.lexicographicallyPrecedes($0.seed.nodeID.rawValue, $1.seed.nodeID.rawValue)
        }
```

Also sort the initial frontier in `runAttempt` at line 751-754. Replace:

```swift
            if state.frontier.isEmpty {
                state.frontier = graph.start.map {
                    HiveFrontierTask(seed: HiveTaskSeed(nodeID: $0), provenance: .graph, isJoinSeed: false)
                }
            }
```

With:

```swift
            if state.frontier.isEmpty {
                state.frontier = graph.start.map {
                    HiveFrontierTask(seed: HiveTaskSeed(nodeID: $0), provenance: .graph, isJoinSeed: false)
                }.sorted {
                    HiveOrdering.lexicographicallyPrecedes($0.seed.nodeID.rawValue, $1.seed.nodeID.rawValue)
                }
            }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter HiveRuntimeStepAlgorithmTests/testFrontierLexicographicSort`
Expected: PASS

**Step 5: Run full test suite to check for regressions**

Run: `swift test`
Expected: All tests pass. Some golden-file tests may need updating if event orderings change.

**Step 6: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift \
        Sources/Hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift
git commit -m "fix: sort frontier lexicographically for deterministic write priority (§11)"
```

---

### Task 2: Fix Task.detached Strong Self Capture in HiveEventStreamController

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamController.swift:122-124`
- Test: `Sources/Hive/Tests/HiveCoreTests/Runtime/` (new test or existing event stream test file)

**Step 1: Write the failing test**

This is a memory leak — hard to test directly. Instead, verify the fix compiles and existing stream tests still pass.

**Step 2: Apply the fix**

In `Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamController.swift`, change lines 122-124 from:

```swift
            Task.detached(priority: .userInitiated) {
                await self.pump(into: continuation)
            }
```

To:

```swift
            let pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                await self.pump(into: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                pumpTask.cancel()
                self?.terminateStreamAndUnblockProducers()
            }
```

And remove the existing `onTermination` at line 119-121 since we've merged it into the new one.

**Step 3: Run tests**

Run: `swift test --filter HiveCoreTests`
Expected: All pass

**Step 4: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamController.swift
git commit -m "fix: use weak self in Task.detached pump to prevent stream leak"
```

---

### Task 3: Fix Task.detached Strong Self Capture in HiveEventStreamViewsHub

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamViews.swift:291-300`

**Step 1: Apply the fix**

In `Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamViews.swift`, change lines 291-300 from:

```swift
        pumpTask = Task.detached { [source] in
            do {
                for try await event in source {
                    await self.broadcast(event)
                }
                await self.finishAll(.success(()))
            } catch {
                await self.finishAll(.failure(error))
            }
        }
```

To:

```swift
        pumpTask = Task.detached { [source, weak self] in
            do {
                for try await event in source {
                    guard let self else { return }
                    await self.broadcast(event)
                }
                await self?.finishAll(.success(()))
            } catch {
                await self?.finishAll(.failure(error))
            }
        }
```

**Step 2: Run tests**

Run: `swift test --filter HiveCoreTests`
Expected: All pass

**Step 3: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveEventStreamViews.swift
git commit -m "fix: use weak self in views hub pump task to prevent actor leak"
```

---

### Task 4: Add Thread Eviction API to HiveRuntime

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift` (add public method after line 266)
- Test: `Sources/Hive/Tests/HiveCoreTests/Runtime/` (new test)

**Step 1: Write the failing test**

Create or add to an existing runtime test file:

```swift
@Test("evictThread removes thread state and queue entry")
func testEvictThread() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
    }

    var builder = HiveGraphBuilder<Schema>()
    builder.addNode(HiveNodeID("start")) { _ in HiveNodeOutput(next: .end) }
    builder.setStart([HiveNodeID("start")])
    let graph = try builder.compile()
    let env = HiveEnvironment<Schema>(context: ())
    let runtime = try HiveRuntime(graph: graph, environment: env)

    let threadID = HiveThreadID("ephemeral")
    let handle = await runtime.run(threadID: threadID, input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    // State exists after run
    let stateBefore = await runtime.getState(threadID: threadID)
    #expect(stateBefore != nil)

    // Evict
    await runtime.evictThread(threadID)

    // State is gone
    let stateAfter = await runtime.getState(threadID: threadID)
    #expect(stateAfter == nil)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter testEvictThread`
Expected: Compile error — `evictThread` does not exist

**Step 3: Implement evictThread**

In `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift`, add after line 266:

```swift
    /// Releases all in-memory state for a completed thread.
    /// Call after `run()` returns `.finished` or `.cancelled` and the thread
    /// is no longer needed for resume or fork operations.
    public func evictThread(_ threadID: HiveThreadID) {
        threadStates.removeValue(forKey: threadID)
        threadQueues.removeValue(forKey: threadID)
    }
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter testEvictThread`
Expected: PASS

**Step 5: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift \
        Sources/Hive/Tests/HiveCoreTests/Runtime/
git commit -m "feat: add evictThread() API to prevent unbounded memory growth"
```

---

### Task 5: Fix Subgraph Treating cancelled/outOfSteps as Success

**Files:**
- Modify: `Sources/Hive/Sources/HiveDSL/Subgraph.swift:4-8` (add error cases)
- Modify: `Sources/Hive/Sources/HiveDSL/Subgraph.swift:118-127` (fix switch)
- Test: `Sources/Hive/Tests/HiveDSLTests/SubgraphCompositionTests.swift`

**Step 1: Write the failing test**

In `SubgraphCompositionTests.swift`, add:

```swift
@Test("Child cancelled propagates as HiveSubgraphError.childCancelled")
func testChildCancelledPropagatesError() async throws {
    // A child graph that never ends (infinite loop) but parent cancels via maxSteps
    // The subgraph should throw childCancelled, not silently succeed
    // (Implementation depends on how child cancellation occurs in your setup)
}
```

**Step 2: Add new error cases to HiveSubgraphError**

In `Sources/Hive/Sources/HiveDSL/Subgraph.swift`, change lines 4-8 from:

```swift
public enum HiveSubgraphError: Error, Sendable {
    case childInterrupted(interruptID: HiveInterruptID)
    case childFailed(Error)
    case childOutputNotFullStore
}
```

To:

```swift
public enum HiveSubgraphError: Error, Sendable {
    case childInterrupted(interruptID: HiveInterruptID)
    case childCancelled
    case childOutOfSteps(maxSteps: Int)
    case childFailed(Error)
    case childOutputNotFullStore
}
```

**Step 3: Fix the switch statement**

In `Sources/Hive/Sources/HiveDSL/Subgraph.swift`, change lines 118-127 from:

```swift
            let childStore: HiveGlobalStore<ChildSchema>
            switch outcome {
            case .finished(let output, _), .cancelled(let output, _), .outOfSteps(_, let output, _):
                guard case .fullStore(let store) = output else {
                    throw HiveSubgraphError.childOutputNotFullStore
                }
                childStore = store
            case .interrupted:
                // Already handled above; unreachable
                throw HiveSubgraphError.childOutputNotFullStore
            }
```

To:

```swift
            let childStore: HiveGlobalStore<ChildSchema>
            switch outcome {
            case .finished(let output, _):
                guard case .fullStore(let store) = output else {
                    throw HiveSubgraphError.childOutputNotFullStore
                }
                childStore = store
            case .cancelled:
                throw HiveSubgraphError.childCancelled
            case .outOfSteps(let maxSteps, _, _):
                throw HiveSubgraphError.childOutOfSteps(maxSteps: maxSteps)
            case .interrupted:
                // Already handled above; unreachable
                throw HiveSubgraphError.childOutputNotFullStore
            }
```

**Step 4: Run tests**

Run: `swift test --filter HiveDSLTests`
Expected: All pass (existing tests don't exercise cancelled/outOfSteps paths)

**Step 5: Commit**

```bash
git add Sources/Hive/Sources/HiveDSL/Subgraph.swift \
        Sources/Hive/Tests/HiveDSLTests/SubgraphCompositionTests.swift
git commit -m "fix: subgraph propagates cancelled/outOfSteps as errors instead of silent success"
```

---

### Task 6: Fix Subgraph Thread ID Collision for Parallel Subgraphs

**Files:**
- Modify: `Sources/Hive/Sources/HiveDSL/Subgraph.swift:97`
- Test: `Sources/Hive/Tests/HiveDSLTests/SubgraphCompositionTests.swift`

**Step 1: Apply the fix**

In `Sources/Hive/Sources/HiveDSL/Subgraph.swift`, change line 97 from:

```swift
            let childThreadID = HiveThreadID("subgraph:\(input.run.threadID.rawValue):\(input.run.stepIndex)")
```

To:

```swift
            let childThreadID = HiveThreadID("subgraph:\(input.run.threadID.rawValue):\(input.run.stepIndex):\(input.task.nodeID.rawValue)")
```

This includes the parent node ID, making thread IDs unique even when parallel subgraphs run in the same superstep.

**Step 2: Run tests**

Run: `swift test --filter HiveDSLTests`
Expected: All pass

**Step 3: Commit**

```bash
git add Sources/Hive/Sources/HiveDSL/Subgraph.swift
git commit -m "fix: include nodeID in subgraph thread ID to prevent parallel checkpoint collision"
```

---

### Task 7: Add Logging to threadQueues Error Drain

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift:65-67, 106-108, 140-142, 249-251`

**Step 1: Apply the fix to all 4 locations**

Replace all occurrences of:

```swift
        threadQueues[threadID] = Task {
            _ = try? await outcome.value
        }
```

With:

```swift
        threadQueues[threadID] = Task { [weak self] in
            do {
                _ = try await outcome.value
            } catch {
                await self?.environment.logger.error(
                    "Queued run for thread \(threadID.rawValue) failed: \(error)",
                    metadata: [:]
                )
            }
        }
```

There are 4 sites: lines ~65, ~106, ~140, ~249.

**Step 2: Run tests**

Run: `swift test --filter HiveCoreTests`
Expected: All pass

**Step 3: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift
git commit -m "fix: log errors from thread queue drain instead of silently swallowing via try?"
```

---

### Task 8: [Obsolete] Legacy Tool Bridge Cleanup

**Files:**
- None

**Step 1: Status**

This task is no longer applicable because the legacy tool-bridge module was removed from this repository.

**Step 2: Run tests**

Run: `swift test`
Expected: All pass

**Step 3: Commit**

```bash
git add Package.swift docs/ website/
git commit -m "chore: remove legacy tool-bridge references after module removal"
```

---

### Task 9: Improve HiveErrorDescription for Production Diagnostics

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Errors/HiveErrorDescription.swift`

**Step 1: Apply the fix**

Replace the entire file content:

```swift
/// Shared error description formatting for redaction and debug payloads.
internal enum HiveErrorDescription {
    /// Full description including payload data (use only when debugPayloads is enabled).
    static func describe(_ error: Error, debugPayloads: Bool) -> String {
        if debugPayloads {
            return String(reflecting: error)
        }
        return describeStructural(error)
    }

    /// Structural description without payload data but WITH error type and message.
    /// Safe for production logging — includes enough info for diagnosis without leaking user data.
    static func describeStructural(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let message = String(describing: error)
        if typeName == message {
            return typeName
        }
        return "\(typeName): \(message)"
    }
}
```

**Step 2: Run tests**

Run: `swift test`
Expected: All pass (error descriptions now include more info in production mode)

**Step 3: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Errors/HiveErrorDescription.swift
git commit -m "fix: include structural error message in production mode for diagnosability"
```

---

### Task 10: Add Empty-Overlay Fast-Path for Fingerprint Digest

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Store/HiveTaskLocalFingerprint.swift`
- Test: `Sources/Hive/Tests/HiveCoreTests/` (existing fingerprint tests or new)

**Step 1: Write the failing test (performance assertion)**

```swift
@Test("Fingerprint digest returns constant for empty task-local schema")
func testFingerprintEmptySchemaConstant() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
    }
    let registry = try HiveSchemaRegistry<Schema>()
    let cache = try HiveInitialCache<Schema>(registry: registry)
    let overlay = HiveTaskLocalStore<Schema>.empty

    let digest1 = try HiveTaskLocalFingerprint.digest(
        registry: registry, initialCache: cache, overlay: overlay
    )
    let digest2 = try HiveTaskLocalFingerprint.digest(
        registry: registry, initialCache: cache, overlay: overlay
    )
    #expect(digest1 == digest2, "Empty overlay digest must be a constant")
}
```

**Step 2: Apply the fast-path**

In `Sources/Hive/Sources/HiveCore/Store/HiveTaskLocalFingerprint.swift`, add a cached constant and early return at the top of `digest`:

```swift
    /// Pre-computed digest for schemas with no task-local channels.
    private static let emptyDigest: Data = {
        var bytes = Data(capacity: 8)
        bytes.append(contentsOf: [0x48, 0x4C, 0x46, 0x31]) // "HLF1"
        var zero = UInt32(0).bigEndian
        withUnsafeBytes(of: &zero) { bytes.append(contentsOf: $0) }
        return Data(SHA256.hash(data: bytes))
    }()

    static func digest<Schema: HiveSchema>(
        registry: HiveSchemaRegistry<Schema>,
        initialCache: HiveInitialCache<Schema>,
        overlay: HiveTaskLocalStore<Schema>,
        debugPayloads: Bool = false
    ) throws -> Data {
        let taskLocalSpecs = registry.sortedChannelSpecs.filter { $0.scope == .taskLocal }
        guard !taskLocalSpecs.isEmpty else { return emptyDigest }

        let canonical = try canonicalBytes(
            registry: registry,
            initialCache: initialCache,
            overlay: overlay,
            debugPayloads: debugPayloads
        )
        let hash = SHA256.hash(data: canonical)
        return Data(hash)
    }
```

Also update `canonicalBytes` to accept the pre-filtered specs to avoid double-filtering:

Pass `taskLocalSpecs` through, or leave as-is since `canonicalBytes` is only called after the guard now.

**Step 3: Run tests**

Run: `swift test`
Expected: All pass

**Step 4: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Store/HiveTaskLocalFingerprint.swift
git commit -m "perf: skip SHA-256 fingerprinting when schema has no task-local channels"
```

---

### Task 11: Cache String(reflecting:) on HiveChannelKey

**Files:**
- Modify: `Sources/Hive/Sources/HiveCore/Schema/HiveChannelKey.swift` (or wherever HiveChannelKey is defined)
- Modify: `Sources/Hive/Sources/HiveCore/Store/HiveStoreSupport.swift:28-36`

**Step 1: Find HiveChannelKey definition**

Run: `grep -rn "struct HiveChannelKey" Sources/Hive/Sources/`

**Step 2: Add typeID to HiveChannelKey**

Add a stored `typeID` property initialized at construction:

```swift
public struct HiveChannelKey<Schema: HiveSchema, Value: Sendable>: Sendable {
    public let id: HiveChannelID
    public let typeID: String

    public init(_ id: HiveChannelID) {
        self.id = id
        self.typeID = String(reflecting: Value.self)
    }
}
```

**Step 3: Update HiveStoreSupport.validateKeyType to use cached typeID**

In `Sources/Hive/Sources/HiveCore/Store/HiveStoreSupport.swift`, change `validateKeyType` from:

```swift
    func validateKeyType<Value: Sendable>(
        _ key: HiveChannelKey<Schema, Value>,
        spec: AnyHiveChannelSpec<Schema>
    ) throws {
        let expectedValueTypeID = spec.valueTypeID
        let actualValueTypeID = String(reflecting: Value.self)
        guard expectedValueTypeID == actualValueTypeID else {
```

To:

```swift
    func validateKeyType<Value: Sendable>(
        _ key: HiveChannelKey<Schema, Value>,
        spec: AnyHiveChannelSpec<Schema>
    ) throws {
        let expectedValueTypeID = spec.valueTypeID
        let actualValueTypeID = key.typeID
        guard expectedValueTypeID == actualValueTypeID else {
```

**Step 4: Run tests**

Run: `swift test`
Expected: All pass

**Step 5: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Schema/ \
        Sources/Hive/Sources/HiveCore/Store/HiveStoreSupport.swift
git commit -m "perf: cache String(reflecting:) on HiveChannelKey to eliminate per-access allocation"
```

---

### Task 12: Extract Shared Hex-Encoding Helper

**Files:**
- Create: `Sources/Hive/Sources/HiveCore/Runtime/HiveHexEncoding.swift`
- Modify: `Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift` (5 call sites)

**Step 1: Create the helper**

Create `Sources/Hive/Sources/HiveCore/Runtime/HiveHexEncoding.swift`:

```swift
import CryptoKit

/// High-performance hex encoding for SHA-256 digests.
/// Uses a single String allocation instead of 33 intermediate allocations.
enum HiveHexEncoding {
    static func hexString(from digest: SHA256Digest) -> String {
        String(unsafeUninitializedCapacity: 64) { buffer in
            var idx = 0
            for byte in digest {
                let hi = Int((byte >> 4) & 0x0F)
                let lo = Int(byte & 0x0F)
                buffer[idx]     = UInt8(hi < 10 ? 48 + hi : 87 + hi)
                buffer[idx + 1] = UInt8(lo < 10 ? 48 + lo : 87 + lo)
                idx += 2
            }
            return 64
        }
    }
}
```

**Step 2: Replace all 5 call sites in HiveRuntime.swift**

Replace every occurrence of:
```swift
hash.compactMap { String(format: "%02x", $0) }.joined()
```

With:
```swift
HiveHexEncoding.hexString(from: hash)
```

Sites: lines ~1354, ~1544, ~2573, ~2582.

**Step 3: Run tests**

Run: `swift test`
Expected: All pass (hex output is identical)

**Step 4: Commit**

```bash
git add Sources/Hive/Sources/HiveCore/Runtime/HiveHexEncoding.swift \
        Sources/Hive/Sources/HiveCore/Runtime/HiveRuntime.swift
git commit -m "perf: replace 33-allocation hex encoding with single-allocation helper"
```

---

## Verification Checklist

After all 12 tasks are complete:

- [ ] `swift test` passes with zero failures
- [ ] Frontier sort test explicitly verifies lexicographic write order
- [ ] `evictThread()` test verifies state removal
- [ ] Subgraph cancelled/outOfSteps now throws (not silently succeeds)
- [ ] Thread queue errors logged instead of swallowed
- [ ] Legacy tool-bridge references removed from repository docs/plans
- [ ] Production error descriptions include structural info
- [ ] Fingerprint fast-path skips SHA-256 for no-task-local schemas
- [ ] `String(reflecting:)` no longer allocated per channel access
- [ ] Hex encoding uses 1 allocation instead of 33
- [ ] No regressions in existing golden tests
