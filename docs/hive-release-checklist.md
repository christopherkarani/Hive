# Hive v1 Release Checklist

## Required Validation
- `cd libs/hive && swift test`
- `cd libs/hive && swift run HiveTinyGraphExample`
- Xcode build: `open libs/hive/Package.swift` and build the `Hive` package for macOS. For iOS, embed the example in an app target and run in a simulator.
- SwiftAgents integration: `cd ../SwiftAgents && swift test` (or your SwiftAgents repo path).

## Definition of Done (§18) Evidence
- Deterministic runs and traces with golden tests:
  - `libs/hive/Tests/HiveCoreTests/Store/HiveTaskLocalFingerprintTests.swift` (golden digests).
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift` (deterministic event ordering + streaming/backpressure).
- Graph introspection + Mermaid export:
  - `libs/hive/Tests/HiveCoreTests/Graph/HiveGraphDescriptionTests.swift` (golden JSON + golden Mermaid + determinism).
- Checkpoint/resume parity:
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveRuntimeCheckpointTests.swift` → `testCheckpointResumeParity_MatchesUninterruptedRun`.
- Send/fan-out and join edges:
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift` → join barrier + fan-out ordering tests.
- Checkpoint inspection (history + load-by-id):
  - `libs/hive/Tests/HiveCoreTests/Checkpointing/HiveCheckpointQueryTests.swift` (type erasure + runtime helpers).
  - `libs/hive/Tests/HiveCheckpointWaxTests/HiveCheckpointWaxStoreQueryTests.swift` (Wax list + load-by-id ordering).
- Stream views:
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveEventStreamViewsTests.swift` (filtering, order, error propagation, cancellation).
- HiveAgents prebuilt graph with tool approval + compaction:
  - SwiftAgents repo tests (per `HIVE_SPEC.md` §16/§18):
    - `testAgentsToolApproval_InterruptsAndResumes()`
    - `testAgentsCompaction_TrimsToBudget_WithoutMutatingMessages()`
    - `testAgentsMessagesReducer_RemoveAll_UsesLastMarker()`
    - `testAgentsModelStream_MissingFinalFails()`
    - `testAgentsToolExecute_AppendsToolMessageWithDeterministicID()`
- `swift test` passes for all targets (HiveCore, HiveConduit, HiveCheckpointWax, Hive).

## Golden Fixture Updates (Intentional)
- If the spec changes, update the golden digest constants in
  - `libs/hive/Tests/HiveCoreTests/Store/HiveTaskLocalFingerprintTests.swift`.
- When updating deterministic event expectations, adjust the expected event ordering in
  - `libs/hive/Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift`.
