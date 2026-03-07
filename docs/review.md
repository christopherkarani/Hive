# Hive Production Readiness Audit

**Date:** 2026-03-07
**Auditor:** Principal Engineer (automated deep review)
**Scope:** Full repository — HiveCore, HiveDSL, HiveConduit, HiveCheckpointWax, HiveRAGWax, HiveSwiftAgents, build configuration, tests
**Swift version:** 6.2 with strict concurrency
**Platforms:** iOS 26+ / macOS 26+

---

## 1. Executive Summary

**Overall Production Readiness Score: 7.0 / 10**

Hive demonstrates strong architectural foundations. The BSP superstep execution model is well-designed, the schema/channel/reducer type system is sound, and the determinism guarantees are enforced with care. The codebase shows evidence of deliberate engineering — lexicographic ordering, checkpoint atomicity, ephemeral channel reset, task-local overlays — all correctly implemented.

However, several gaps block a confident production release.

### Top 5 Critical Risks

| # | Risk | Severity | Section |
|---|------|----------|---------|
| 1 | `@unchecked Sendable` on `HiveEventStreamController` with manual NSCondition synchronization — correctness depends entirely on locking discipline with no compiler verification | Major | §4.1 |
| 2 | Pre-1.0 external dependencies (`Conduit 0.3.x`, `Wax 0.1.x`) with open-ended semver ranges — any minor version bump can break the build | Major | §3.3 |
| 3 | `HiveRuntime.swift` is a ~2,900-line monolith that contains the entire execution engine, making it extremely difficult to review, test, or modify safely | Major | §3.1 |
| 4 | No CI pipeline runs tests — existing GitHub Actions workflows are only for Claude code assistance, not build/test/lint | Blocker | §8.1 |
| 5 | Type identity matching uses `String(reflecting:)` which can produce different strings for the same type across module boundaries | Major | §2.3 |

### Release Blockers

1. **No CI test pipeline.** There is zero automated verification that the main branch builds and tests pass. This is a hard blocker for any production release.
2. **Missing `HiveMacros` module.** CLAUDE.md documents `HiveMacros / HiveMacrosImpl` as part of the architecture, and the test filter `HiveMacrosTests` is referenced. The module does not exist in the repository. Either ship it or remove all references.

---

## 2. Correctness Issues

### 2.1 Router Sees Partial Global State — By Design but Subtle (Minor)

**File:** `HiveRuntime.swift:2273-2283`

When computing the next frontier after a step, routers receive a `HiveStoreView` built from `applyGlobalWritesForTask()`, which applies only the writes from that task's index to the pre-step global store. This means the router sees the pre-step global + only its own task's writes, NOT the fully committed post-step state.

This is consistent with the BSP model (routers run before the commit is finalized), but it means routers can make different decisions than they would if they saw the full post-step state. This is documented behavior, not a bug, but it is a subtle footgun for users.

**Recommendation:** Add explicit documentation on `HiveRouter` that the store view provided reflects pre-commit state with only the current task's writes applied.

### 2.2 `runFinished` Event Emitted on Error Paths (Minor)

**File:** `HiveRuntime.swift:1037`

In `executeRunLoop`, the only catch block is for `RuntimeCancellation`. All other errors (checkpoint save failure, build output errors, emit streaming errors) propagate uncaught to the caller. The caller (`runAttempt` at line 771-773) catches them and calls `streamController.finish(throwing: error)` without emitting any terminal event.

This means consumers of the event stream will see the stream terminate with an error but will NOT receive a terminal event like `.runFailed`. The stream simply ends. This is not a correctness bug, but it breaks the pattern of "every run emits a terminal event."

**Recommendation:** Add a `.runFailed` event kind or emit `.runFinished` with metadata indicating failure.

### 2.3 Type Identity via `String(reflecting:)` is Fragile (Major)

**File:** `HiveChannelTypeRegistry.swift:18`

```swift
let expectedValueTypeID = String(reflecting: Value.self)
```

`String(reflecting:)` produces module-qualified type names (e.g., `ModuleName.TypeName`). If the same type is imported under different module names (e.g., via `@_exported import`), or if a type is defined in an extension in a different module, the string representations may not match. This would cause spurious `channelTypeMismatch` errors at runtime.

**Recommendation:** Consider using `ObjectIdentifier(Value.self)` for type comparison, which is based on the actual metatype identity rather than string representation. Alternatively, document this limitation prominently.

### 2.4 Version Counter Wrapping (Theoretical, Low)

**File:** `HiveRuntime.swift:1744`

```swift
nextState.channelVersionsByChannelID[channelID] = current &+ 1
```

The `&+` operator wraps on overflow. If a channel receives more than `UInt64.max` writes, the version wraps to 0. The trigger filter at line 1865 uses `current > seenValue`, which would evaluate incorrectly after wrapping.

In practice, UInt64.max is ~1.8×10¹⁹, making this impossible to reach. However, the use of wrapping arithmetic (`&+`) is intentional but uncommented, which could confuse future maintainers.

**Recommendation:** Add a comment explaining why `&+` is used and why wrapping is acceptable.

### 2.5 Checkpoint Decode Discards `deferredFrontier` (Minor)

**File:** `HiveRuntime.swift:680`

```swift
return ThreadState(
    ...
    deferredFrontier: [],  // Always empty after checkpoint decode
    ...
)
```

When decoding a checkpoint, `deferredFrontier` is always set to `[]`. If a checkpoint was saved while deferred nodes existed but hadn't yet been promoted to the frontier, those deferred nodes are permanently lost on resume. This is only safe if checkpoints are only saved at step boundaries where deferral has already been resolved.

The current code saves checkpoints only after a step commit (line 961-967), and the frontier/deferred resolution happens at the top of the run loop (lines 921-927). So deferred nodes ARE resolved before checkpoint save IF the checkpoint policy is `everyStep`. However, with `onInterrupt`, if an interrupt occurs in a step that produced deferred tasks, those deferred tasks would be lost.

**Recommendation:** Either serialize `deferredFrontier` in checkpoints or document this as a known limitation.

### 2.6 Empty `start` Array Not Checked at Runtime (Minor)

**File:** `HiveRuntime.swift:742`

```swift
if state.frontier.isEmpty {
    state.frontier = graph.start.map { ... }
}
```

If `graph.start` is empty (which should be prevented by compilation), the frontier remains empty and the run immediately finishes with `.finished`. The graph builder validates `start.isEmpty` (line 213), but if `CompiledHiveGraph` is constructed directly (it has a public init via struct), an empty start could slip through.

**Recommendation:** Make `CompiledHiveGraph` init `internal` or add a runtime assertion.

---

## 3. Architecture & Design Gaps

### 3.1 HiveRuntime.swift is a 2,900-Line Monolith (Major)

**File:** `HiveRuntime.swift` — 111KB, ~2,900 lines

This single file contains:
- Public API (`run`, `resume`, `fork`, `applyExternalWrites`, `getState`)
- Thread state management
- The BSP superstep loop
- Task execution and retry logic
- Checkpoint serialization/deserialization
- Write collection and commit logic
- Frontier computation (static edges, routers, joins)
- Trigger filtering
- Event emission and streaming
- Cache management

This is the most complex module and the highest-risk file in the repository. Any change requires understanding the full context. The MARK sections help navigation but don't prevent cross-cutting concerns from interleaving.

**Recommendation:** Extract into focused files:
- `HiveRuntime+PublicAPI.swift`
- `HiveRuntime+StepExecution.swift`
- `HiveRuntime+CommitAndFrontier.swift`
- `HiveRuntime+Checkpoint.swift`
- `HiveRuntime+TaskExecution.swift`

### 3.2 Missing HiveMacros Module (Blocker)

**Files:** CLAUDE.md references `HiveMacros / HiveMacrosImpl` and `@HiveSchema`, `@Channel`, `@TaskLocalChannel`, `@WorkflowBlueprint` macros. No macro source files exist in the repository.

This creates confusion for contributors and consumers: the documented API surface does not match the shipped code.

**Recommendation:** Either implement the macros module or remove all references from documentation.

### 3.3 Pre-1.0 Dependencies with Open Semver Ranges (Major)

**File:** `Package.swift:22-23`

```swift
.package(url: "https://github.com/christopherkarani/Conduit", from: "0.3.1"),
.package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.3"),
```

Both dependencies are pre-1.0 (`0.x.y`). Under semantic versioning, `0.x` versions make no stability guarantees — even minor version bumps can contain breaking changes. The `from:` operator resolves to `0.3.1..<1.0.0` and `0.1.3..<1.0.0` respectively, meaning a `0.4.0` release of Conduit or a `0.2.0` release of Wax would be automatically picked up and could break the build.

**Recommendation:** Pin to exact versions or use tighter ranges: `"0.3.1"..<"0.4.0"`.

### 3.4 Dual Package.swift Files (Minor)

**Files:** `/Package.swift` and `/Sources/Hive/Package.swift`

Two Package.swift files exist with similar but not identical configurations. The root one is authoritative (used by `swift build`), while the nested one appears vestigial from when the source was in a `libs/hive/` directory structure.

**Recommendation:** Remove `/Sources/Hive/Package.swift` to avoid confusion.

### 3.5 `CompiledHiveGraph` Has Public Struct Init (Minor)

**File:** `HiveGraphBuilder.swift:63-82`

`CompiledHiveGraph` is a public struct with all stored properties, meaning anyone can construct one directly without going through `HiveGraphBuilder.compile()`, bypassing all validation (no duplicate nodes, no invalid node IDs, no empty start, etc.).

**Recommendation:** Make `CompiledHiveGraph.init` internal, or use an access-control wrapper.

---

## 4. Concurrency & Safety

### 4.1 `@unchecked Sendable` on HiveEventStreamController (Major)

**File:** `HiveEventStreamController.swift:11`

```swift
internal final class HiveEventStreamController: @unchecked Sendable {
```

This class uses NSCondition for manual synchronization. The locking discipline appears correct on inspection: every access to `queue` and `finishState` is within `condition.lock()`/`condition.unlock()` pairs. However, `@unchecked Sendable` disables all compiler verification of thread safety. A single missed lock in a future modification would introduce a data race with no compiler warning.

The `pump(into:)` method (line 209) uses a polling loop with `Task.sleep(nanoseconds: 250_000)` for non-droppable events when the continuation buffer is full. This is a 250µs busy-wait loop that could consume CPU unnecessarily.

**Recommendation:** Consider replacing with a Swift concurrency-native approach (e.g., `AsyncStream` with manual continuation management) or adding TSan annotations.

### 4.2 `Task.detached` in makeStream (Minor)

**File:** `HiveEventStreamController.swift:122`

```swift
Task.detached(priority: .userInitiated) {
    await self.pump(into: continuation)
}
```

This creates an unstructured, detached task that runs the pump loop. If the `HiveEventStreamController` is deallocated while this task is running, the `self` capture keeps it alive. The pump loop exits when the stream is finished or terminated, but there's no explicit cancellation mechanism.

**Recommendation:** Consider tracking this task and cancelling it on deinit, or document why leaking until natural termination is acceptable.

### 4.3 `weak self` in run() Creates Surprising Failure Mode (Minor)

**File:** `HiveRuntime.swift:48-54`

```swift
let outcome = Task { [weak self] in
    if let previous { await previous.value }
    guard let self else { throw CancellationError() }
    return try await self.runAttempt(...)
}
```

If the `HiveRuntime` actor is deallocated between creating the `HiveRunHandle` and the queued task executing, the run throws `CancellationError()`. This is correct behavior but may surprise callers who receive a `CancellationError` without having cancelled anything.

**Recommendation:** Throw a more descriptive error like `HiveRuntimeError.runtimeDeallocated`.

### 4.4 Actor Isolation is Clean (Positive Finding)

The `HiveRuntime` actor properly isolates all mutable state (`threadStates`, `threadQueues`). The `static func executeTasks()` and `static func executeTask()` methods are correctly static and only access their parameters. The `environmentSnapshot` nonisolated property is a let-bound value type copy. No actor isolation violations were found.

---

## 5. Performance Bottlenecks

### 5.1 Sorted Iteration in commitStep (Minor)

**File:** `HiveRuntime.swift:2196-2210`

```swift
for spec in registry.sortedChannelSpecs where spec.scope == .global {
    guard let writes = globalWritesByChannel[spec.id], !writes.isEmpty else { continue }
    let ordered = writes.sorted { ... }
    ...
}
```

Each commit sorts writes per channel. With `N` channels and `W` writes per channel, this is `O(N + W·log(W))` per step. For typical workflow graphs (tens of channels, single-digit writes per step), this is negligible. For high-fan-out scenarios with many task-local channels, the nested loop over `registry.sortedChannelSpecs` for each task (line 2230) could become noticeable.

**Assessment:** Not a bottleneck for expected use cases. Acceptable.

### 5.2 Ring Buffer Allocation in EventStreamController (Low)

**File:** `HiveEventStreamController.swift:33`

```swift
self.storage = Array(repeating: nil, count: capacity)
```

The ring buffer pre-allocates `capacity` optional slots. With the default event buffer capacity, this is fine. But a caller could set `eventBufferCapacity` to a very large number, allocating a large array eagerly.

**Recommendation:** Cap the maximum capacity or use a lazy allocation strategy.

### 5.3 CryptoKit SHA256 on Every Task ID (Low)

**File:** `HiveRuntime.swift` imports `CryptoKit`

Task IDs are generated via SHA256 hashing of run ID, step index, node ID, ordinal, and local fingerprint. This runs once per task per step. SHA256 is fast (~100ns per hash for small inputs), so this is negligible for typical workflows.

**Assessment:** Acceptable.

### 5.4 Dictionary Copies in Value-Type ThreadState (Minor)

`ThreadState` is a value type containing multiple dictionaries (`channelVersionsByChannelID`, `versionsSeenByNodeID`, `nodeCaches`). On every `state = nextState` assignment, these are copied. Swift's copy-on-write for Dictionary means the actual copy is deferred until mutation, but the pattern of `var nextState = state; nextState.x = ...; state = nextState` guarantees mutation and therefore a full copy.

For large graphs with many nodes and channels, these dictionary copies could accumulate.

**Recommendation:** Consider making `ThreadState` a reference type (class) or using in-place mutation more aggressively.

---

## 6. Security Risks

### 6.1 No Input Validation on HiveChannelID / HiveNodeID (Low)

**Files:** `HiveChannelID.swift`, `HiveIdentifiers.swift`

`HiveChannelID` and `HiveNodeID` accept arbitrary strings with no validation at construction time. Node ID validation (no `:` or `+` characters) only occurs during graph compilation. If IDs are constructed from user input (e.g., in a dynamic workflow builder), there's no defense-in-depth against malformed IDs.

**Recommendation:** Add `precondition` or `assert` checks in ID initializers.

### 6.2 Error Messages May Leak Internal State (Low)

**File:** `HiveErrorDescription.swift`

When `debugPayloads` is true, error descriptions include the full payload content. This is intended for development but could leak sensitive data if errors are logged to external systems.

**Assessment:** The `debugPayloads` flag properly gates this behavior. Acceptable if documentation warns against enabling in production.

### 6.3 Checkpoint Data is Not Encrypted (Low)

Checkpoints contain serialized channel data as raw `Data` blobs. If the checkpoint store persists to disk (e.g., via Wax), sensitive channel values are stored in plaintext.

**Recommendation:** Document this limitation. Consider supporting encrypted codecs for sensitive channels.

---

## 7. Testing Review

### 7.1 Test Coverage Assessment

| Module | Test Files | Coverage Assessment |
|--------|-----------|-------------------|
| HiveCore/Runtime | 11 files (~185K) | **Strong.** Step algorithm, checkpoint, interrupt/resume, errors/retries, streaming, cache/fork, channel versioning, event streams all covered. |
| HiveCore/Schema | 2 files | **Adequate.** Schema registry and barrier topic channels tested. |
| HiveCore/Store | 4 files | **Adequate.** Initial cache, store errors, task-local fingerprint, untracked reset tested. |
| HiveCore/DataStructures | 2 files | **Good.** Bitset and inverted index tested. |
| HiveCore/Graph | 3 files | **Good.** Graph description, static layers, versioning goldens tested. |
| HiveDSL | 8 files (~80K) | **Strong.** Smoke tests, model turn, effects, subgraph composition, patch/diff, compilation all covered. |
| HiveConduit | 3 files | **Adequate.** Smoke, streaming, integration tested. |
| HiveCheckpointWax | 3 files | **Adequate.** Smoke, load latest, query tested. |
| HiveRAGWax | 1 file | **Minimal.** Only basic store tests. |
| HiveSwiftAgents | 1 file | **Minimal.** Only smoke test. |
| Hive (umbrella) | 1 file | **Minimal.** Only smoke test. |

### 7.2 Missing Test Coverage (Major Gaps)

1. **No stress/load testing.** All tests use small graphs (2-5 nodes). There are no tests with 100+ nodes, 1000+ tasks, or high concurrency. Frontier computation, join resolution, and commit performance under load are untested.

2. **No chaos/failure-injection testing.** Tests don't simulate:
   - Checkpoint store failures during save
   - Clock failures during retry backoff
   - Memory pressure during large step commits
   - Concurrent runs on the same thread ID

3. **No property-based testing.** The determinism guarantee is tested via hand-crafted examples. Property-based tests (e.g., "for any valid graph and input, two runs produce identical event sequences") would be far more robust.

4. **No fuzz testing on checkpoint decode.** The checkpoint decode path accepts `Data` blobs and deserializes them. Malformed checkpoint data should be handled gracefully, but this isn't tested systematically.

5. **`HiveRAGWax` has minimal coverage.** Only one test file exists for the RAG store module.

6. **`HiveSwiftAgents` has minimal coverage.** Only a smoke test exists for the Swift Agents integration module.

### 7.3 Test Infrastructure Quality (Positive)

The test infrastructure is well-designed:
- Consistent use of Swift Testing framework (`@Test`, `#expect`, `#require`)
- Inline schemas per test avoid shared mutable state
- `TestClock` and `TestLogger` noop implementations are simple and correct
- Event collection via `collectEvents()` pattern is clean and reusable
- Determinism assertions check exact event ordering

---

## 8. Build & Infrastructure

### 8.1 No CI Test Pipeline (Blocker)

**Files:** `.github/workflows/claude.yml`, `.github/workflows/claude-code-review.yml`

Both existing GitHub Actions workflows are for Claude code assistance (code review, issue handling). Neither runs `swift build` or `swift test`. There is no automated verification that the codebase compiles and tests pass.

**Recommendation:** Add a CI workflow that runs:
```yaml
- swift build
- swift test
- swift test --filter HiveCoreTests
- swift test --filter HiveDSLTests
# ... all test targets
```

### 8.2 No Linting or Formatting Configuration (Minor)

No `.swiftlint.yml`, `.swift-format`, or similar configuration files exist. Code style is consistent throughout the repository (likely maintained by convention), but there's no automated enforcement.

**Recommendation:** Add SwiftFormat or SwiftLint with a minimal configuration to prevent style drift.

### 8.3 Test Target Uses Compile-Time Flag (Info)

**File:** `Package.swift:89-91`

```swift
swiftSettings: [
    .define("HIVE_V11_TRIGGERS"),
]
```

`HiveCoreTests` defines `HIVE_V11_TRIGGERS`, which presumably enables tests for the v11 trigger feature. This is fine for feature-flagging tests, but the flag is only defined on the test target, not the source target. If the flag guards behavior in source code via `#if`, those code paths would not be compiled in the main target.

**Recommendation:** Verify that this flag is only used in test files, not in source files.

### 8.4 Executable Target in Library Package (Minor)

**File:** `Package.swift:19`

```swift
.executable(name: "HiveTinyGraphExample", targets: ["HiveTinyGraphExample"]),
```

An executable product (`HiveTinyGraphExample`) is included in the package products list. This means consumers who depend on the Hive package will see this executable target. It should be excluded from the products list or moved to a separate package.

**Recommendation:** Remove from `products` (keep as a target for `swift run` but don't export it).

---

## 9. Refactoring Opportunities

### 9.1 Extract Frontier Computation (High Value)

The frontier computation logic in `commitStep` (lines 2250-2400+) handles static edges, routers, join edges, spawn seeds, and deferred nodes. This ~150-line block is interleaved with the write commit logic. Extracting it into a `computeNextFrontier()` method would make both commit and frontier logic independently testable.

### 9.2 Unify Validation Helper Pattern

**File:** `HiveSchemaRegistry.swift:41-101`

Three private methods (`firstDuplicateID`, `firstInvalidTaskLocalUntrackedID`, `firstMissingRequiredCodecID`) share identical "find smallest matching element" logic with different predicates. This could be a single generic helper:

```swift
private static func firstMatching(
    in specs: [AnyHiveChannelSpec<Schema>],
    where predicate: (AnyHiveChannelSpec<Schema>) -> Bool
) -> HiveChannelID?
```

### 9.3 Reduce `HiveGraphBuilder.compile()` Complexity

**File:** `HiveGraphBuilder.swift:129-210`

The `compile()` method is 80 lines of sequential construction. The join edge processing block (lines 154-176) could be extracted into a helper, improving readability.

### 9.4 Naming: `HiveStoreSupport` is Vague

**File:** `HiveStoreSupport.swift`

This type provides scope validation and type casting for stores. A more descriptive name like `HiveStoreAccessValidator` or `HiveChannelAccessControl` would better communicate its purpose.

---

## 10. Summary of Findings by Severity

### Blockers (Must Fix Before Release)

| ID | Finding | Section |
|----|---------|---------|
| B-1 | No CI pipeline runs tests | §8.1 |
| B-2 | Missing HiveMacros module (documented but not implemented) | §3.2 |

### Major (Should Fix Before Release)

| ID | Finding | Section |
|----|---------|---------|
| M-1 | `@unchecked Sendable` on HiveEventStreamController | §4.1 |
| M-2 | Pre-1.0 dependencies with open semver ranges | §3.3 |
| M-3 | HiveRuntime.swift is a 2,900-line monolith | §3.1 |
| M-4 | `String(reflecting:)` type identity is fragile | §2.3 |
| M-5 | No stress, chaos, or property-based testing | §7.2 |

### Minor (Fix When Convenient)

| ID | Finding | Section |
|----|---------|---------|
| m-1 | `runFinished` event not emitted on error paths | §2.2 |
| m-2 | Checkpoint decode discards deferredFrontier | §2.5 |
| m-3 | Dual Package.swift files | §3.4 |
| m-4 | `CompiledHiveGraph` has public struct init | §3.5 |
| m-5 | `Task.detached` pump loop has no explicit cancellation | §4.2 |
| m-6 | `weak self` throws generic CancellationError | §4.3 |
| m-7 | No linting/formatting enforcement | §8.2 |
| m-8 | Executable target exported in products | §8.4 |
| m-9 | HiveRAGWax and HiveSwiftAgents have minimal test coverage | §7.2 |

### Positive Findings

- Actor isolation is correctly implemented throughout
- Checkpoint atomicity is correctly enforced (save failure prevents commit)
- Deterministic write ordering via lexicographic node/channel sorting is sound
- BSP superstep model faithfully implements the spec
- Thread serialization via queued Tasks is a clean pattern
- Schema registry validation catches duplicates, invalid scopes, and missing codecs at compile time
- Graph builder validation is thorough (structure, endpoints, joins, routers)
- Test infrastructure uses good patterns (inline schemas, event collection, determinism assertions)
- Error types are comprehensive and descriptive
- Ephemeral channel reset is correctly placed after step commit

---

*End of audit.*
