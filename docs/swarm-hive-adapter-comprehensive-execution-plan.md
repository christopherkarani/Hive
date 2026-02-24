# Swarm -> Hive Adapter: Comprehensive Execution Plan

Date: February 24, 2026
Owner: Swarm runtime/orchestration team
Primary repo for implementation: `Swarm`
Reference runtime backend: `Hive` (Swift 6.2)

## 1) Mission
Build a production-grade `Swarm -> Hive` adapter so Swarm can execute orchestration workloads on Hive with:
- deterministic runtime behavior
- durable checkpoint/interrupt/resume semantics
- strict contract mapping (no silent fallback)
- reliable CI gating

## 2) Prompt Location
Execution prompt is intentionally kept separate at:
`docs/swarm-hive-adapter-execution-prompt.md`

## 3) Scope And Boundaries
In scope:
- Adapter layer in Swarm that translates Swarm runtime contract to Hive runtime APIs.
- Contract tests validating behavior, not just type compatibility.
- Replay/soak determinism validation.
- CI path resilient to runner instability.

Out of scope:
- Refactoring Hive public APIs unless a hard blocker is discovered.
- Reintroducing SwiftAgents compatibility code.

## 4) Canonical Contract Mapping

| Swarm contract surface | Hive API | Adapter requirement |
|---|---|---|
| Run start | `HiveRuntime.run(...)` | Map input/options/thread identity deterministically |
| Resume interrupt | `HiveRuntime.resume(...)` | Strict interrupt ID match and resume payload mapping |
| Cancel run | `Task.cancel()` on outcome task | Normalize to Swarm cancelled outcome contract |
| External writes | `HiveRuntime.applyExternalWrites(...)` | Preserve frontier and step-index semantics |
| State read | `HiveRuntime.getState(...)` | Provide consistent snapshot/null behavior |
| Fork | `HiveRuntime.fork(...)` | Preserve checkpoint lineage semantics |
| Event stream | `HiveRunHandle.events` | Deterministic translation + ordering-preserving projection |
| Run options | `HiveRunOptions` | Explicit defaults + unsupported option rejection |
| Outcome mapping | `HiveRunOutcome` | Canonical Swarm result enum + typed failure mapping |
| Checkpoint query | `loadLatest/list/query` capabilities | Feature-detect + typed unsupported responses |

## 5) Phased Delivery Plan

### Phase 0: Baseline Contract Inventory (Day 0-1)
Goals:
- freeze Swarm runtime contract expectations
- identify unmapped fields and ambiguous semantics

Tasks:
1. Enumerate Swarm runtime entry points and payload types.
2. Produce initial matrix: `field -> Hive source -> status`.
3. Mark high-risk semantics:
   - cancellation vs error mapping
   - interrupt lifecycle
   - checkpoint/fork lineage
   - streaming ordering

Exit criteria:
- baseline matrix committed
- no unknown contract fields remain

### Phase 1: Adapter Skeleton + Option Normalization (Day 1-2)
Goals:
- install strict translation boundary

Tasks:
1. Implement `SwarmHiveRuntimeAdapter` facade.
2. Implement mappers:
   - request mapper
   - option mapper
   - outcome mapper
   - event mapper
   - error mapper
3. Add typed unsupported-option failures.
4. Add adapter-level logging hooks for traceability.

Exit criteria:
- adapter compiles
- unit tests cover default/override option mapping

### Phase 2: Core Runtime Semantics (Day 2-4)
Goals:
- contract correctness for execution lifecycle

Tasks:
1. Run path (start -> finish).
2. Interrupt + resume path.
3. Cancellation path including cancel-during-persist behavior.
4. External writes semantics.
5. State reads + fork path.

Exit criteria:
- integration tests pass for all lifecycle operations

### Phase 3: Event/Streaming Determinism (Day 3-5)
Goals:
- stable transcript semantics for orchestration and replay

Tasks:
1. Define canonical Swarm event projection schema.
2. Ensure ordering-preserving translation.
3. Add deterministic transcript serializer (stable key order, normalized timestamps if required).
4. Add transcript golden tests for representative flows.

Exit criteria:
- deterministic event transcript test set green

### Phase 4: Soak + Replay Validation (Day 5-7)
Goals:
- prove long-running deterministic behavior

Tasks:
1. Build seeded workload generator:
   - periodic interrupts
   - resumptions
   - external writes
   - mixed branching
2. Run N repeated executions (e.g., 25+ same seed).
3. Compare hashes:
   - final state hash
   - normalized transcript hash
4. Emit first divergence diff if any mismatch.

Exit criteria:
- no hash divergence across repeated seeded runs

### Phase 5: CI Hardening + Release Gate (Day 6-8)
Goals:
- production-ready quality gate

Tasks:
1. Add stable isolated-runner path for adapter test subset.
2. Keep monolithic test job, but gate merges on:
   - adapter contract suite
   - determinism suite
3. Add flaky-test policy and retry budget (if needed).

Exit criteria:
- PR pipeline reliably enforces adapter contract

## 6) Swarm Test Layout (Recommended)

```text
Swarm/
  Sources/
    SwarmRuntimeHive/
      SwarmHiveRuntimeAdapter.swift
      SwarmHiveRequestMapper.swift
      SwarmHiveOptionMapper.swift
      SwarmHiveOutcomeMapper.swift
      SwarmHiveEventMapper.swift
      SwarmHiveErrorMapper.swift

  Tests/
    SwarmRuntimeHiveTests/
      Unit/
        SwarmHiveOptionMapperTests.swift
        SwarmHiveErrorMapperTests.swift
        SwarmHiveEventMapperTests.swift
        SwarmHiveOutcomeMapperTests.swift
      Integration/
        SwarmHiveRunContractTests.swift
        SwarmHiveInterruptResumeContractTests.swift
        SwarmHiveCancellationContractTests.swift
        SwarmHiveExternalWritesContractTests.swift
        SwarmHiveForkAndStateContractTests.swift
        SwarmHiveStreamingContractTests.swift
      Determinism/
        SwarmHiveReplayDeterminismTests.swift
        SwarmHiveSoakDeterminismTests.swift
      Fixtures/
        TranscriptFixtures/
        StateFixtures/
```

Naming conventions:
- Unit tests: `<TypeUnderTest>Tests.swift`
- Integration tests: `SwarmHive<Surface>ContractTests.swift`
- Determinism tests: `SwarmHive<Mode>DeterminismTests.swift`

Test case naming:
- `test<Surface>_<Condition>_<ExpectedBehavior>()`
- examples:
  - `testResume_UnknownInterruptID_ThrowsTypedContractError()`
  - `testCancel_DuringCheckpointSave_ReturnsCancelledWithoutCommit()`
  - `testExternalWrites_PreservesFrontierAndIncrementsStepIndex()`

## 7) Required Contract Test Matrix

### Unit
1. option defaults map exactly to Hive defaults
2. explicit options override defaults
3. unsupported option combinations throw typed adapter error
4. outcome mapping preserves `.finished/.interrupted/.cancelled/.outOfSteps`
5. error mapping preserves typed classification
6. event mapping preserves ordering + IDs + payload shape

### Integration
1. run happy path returns expected final output
2. interrupt then resume with valid payload succeeds
3. resume with wrong interrupt ID fails typed
4. cancel during checkpoint persistence returns cancelled semantics
5. external writes persist and future run continues from expected frontier
6. fork from checkpoint produces independent thread lineage
7. getState returns expected snapshot fallback behavior
8. streaming mode parity (`events/values/updates/combined` as supported)

### Negative
1. malformed checkpoint state rejected deterministically
2. missing checkpoint store + checkpoint policy requiring store throws typed config error
3. unsupported checkpoint query capability returns typed unsupported error
4. malformed external write (unknown/task-local mismatch) rejected with no partial commit

## 8) Determinism/Replay Protocol
1. Build normalized transcript format:
   - stable event enum names
   - stable field ordering
   - normalize nondeterministic metadata where contract allows
2. Seed workload with deterministic seed input.
3. Execute repeated runs with identical seed and options.
4. Compute:
   - `transcriptHash`
   - `finalStateHash`
5. Fail fast on first mismatch and print minimal structural diff.
6. Store mismatch artifacts for CI inspection.

## 9) CI Blueprint
Jobs:
1. `adapter-unit-contract`
   - fast unit + integration contract suite
2. `adapter-determinism`
   - replay determinism suite (seeded repeated runs)
3. `full-tests`
   - full Swarm test pass (non-gating initially if flaky)

Gate recommendation:
- required: `adapter-unit-contract`, `adapter-determinism`
- advisory: `full-tests` until monolithic stability is proven

## 10) Ranked Backlog Template (Fill During Execution)

| Rank | Item | Severity | User impact | Complexity | Recommended order |
|---|---|---|---|---|---|
| 1 | Adapter contract completeness gaps | High | High | Medium | Immediate |
| 2 | Replay/soak determinism divergence | High | High | High | Immediate |
| 3 | Monolithic test-runner instability | Medium | Medium | Medium | After contract green |
| 4 | API ergonomics polish | Medium | Medium | Low | After semantics lock |
| 5 | Additional docs/examples | Low | Medium | Low | Final pass |

## 11) Release Exit Criteria
All must be true:
1. Contract matrix complete with no unknown mappings.
2. All required contract tests green.
3. Determinism replay suite green across repeated seeded runs.
4. No silent fallback behavior for unsupported features.
5. Typed, documented error semantics for all rejected paths.
6. Final change summary includes exact file references and test evidence.

## 12) Implementation Checklist
- [ ] baseline contract matrix committed
- [ ] adapter façade + mappers implemented
- [ ] strict option validation implemented
- [ ] lifecycle contract integration tests added
- [ ] determinism/replay suite added
- [ ] CI gating wired
- [ ] backlog ranked and documented
- [ ] release evidence package prepared
