# Hive v1 plan parity map (spec → plans)

This file maps the normative test matrix in `HIVE_SPEC.md` §17.2 to the plan folders in `plans/hive-v1/`.

If a test exists in the spec matrix but is not mapped here, treat that as a planning bug.

## Test matrix coverage

### `00-scaffold`

- (No spec matrix items; scaffold only)

### `01-schema-channels-codecs-writes`

- (No spec matrix items; foundations used by compilation/runtime later.)

### `02-reducers-update-policy`

- (Reducer semantics are pinned here; commit-time updatePolicy enforcement is pinned in `05-*` / `07-*`.)

### `03-store-model-fingerprint`

- `testInitialCache_EvaluatedOnceInLexOrder()`
- `testTaskLocalFingerprint_EmptyGolden()`
- `testTaskLocalFingerprintEncodeFailure_Deterministic()`

### `04-graph-builder-compilation-versioning`

- `testSchemaVersion_GoldenHSV1()`
- `testGraphVersion_GoldenHGV1()`
- `testCompile_DuplicateChannelID_Fails()`
- `testCompile_TaskLocalUntracked_Fails()`
- `testCompile_NodeIDReservedJoinCharacters_Fails()`

### `05-runtime-step-algorithm-core`

- `testRouterFreshRead_SeesOwnWriteNotOthers()`
- `testRouterFreshRead_ErrorAbortsStep()`
- `testRouterReturnUseGraphEdges_FallsBackToStaticEdges()`
- `testGlobalWriteOrdering_DeterministicUnderRandomCompletion()`
- `testDedupe_GraphSeedsOnly()`
- `testFrontierOrdering_GraphBeforeSpawn()`
- `testJoinBarrier_IncludesSpawnParents()`
- `testJoinBarrier_TargetRunsEarly_DoesNotReset()`
- `testJoinBarrier_ConsumeOnlyWhenAvailable()`
- `testUnknownChannelWrite_FailsNoCommit()`

### `06-events-streaming-backpressure`

- `testEventSequence_DeterministicEventsOrder()`
- `testFailedStep_NoStepFinishedOrWriteApplied()`
- `testDebugPayloads_WriteAppliedMetadata()`
- `testDeterministicTokenStreaming_BuffersStreamEvents()`
- `testBackpressure_ModelTokensCoalesceAndDropDeterministically()`

### `07-errors-retries-cancellation-limits`

- `testUpdatePolicySingle_GlobalViolatesAcrossTasks_FailsNoCommit()`
- `testUpdatePolicySingle_TaskLocalPerTask_AllowsAcrossTasks()`
- `testReducerThrows_AbortsStep_NoCommit()`
- `testMultipleTaskFailures_ThrowsEarliestOrdinalError()`
- `testCommitFailurePrecedence_UnknownChannelBeatsUpdatePolicy()`
- `testOutOfSteps_StopsWithoutExecutingAnotherStep()`

### `08-interrupt-resume-external-writes`

- `testInterrupt_SelectsEarliestTaskOrdinal()`
- `testInterruptID_DerivedFromTaskID()`
- `testResume_FirstCommitClearsInterruption()`
- `testResume_CancelBeforeFirstCommit_KeepsInterruption()`
- `testResume_VisibleOnlyFirstStep()`
- `testApplyExternalWrites_IncrementsStepIndex_KeepsFrontier()`
- `testApplyExternalWrites_RejectsTaskLocalWrites()`

### `09-checkpointing-wax`

- `testCheckpoint_PersistsFrontierOrderAndProvenance()`
- `testCheckpoint_StepIndexIsNextStep()`
- `testCheckpointID_DerivedFromRunIDAndStepIndex()`
- `testCheckpointDecodeFailure_FailsBeforeStep0()`
- `testCheckpointCorrupt_JoinBarrierKeysMismatch_FailsBeforeStep0()`
- `testCheckpointSaveFailure_AbortsCommit()`
- `testCheckpointEncodeFailure_AbortsCommitDeterministically()`
- `testCheckpointLoadThrows_FailsBeforeStep0()`
- `testResume_VersionMismatchFailsBeforeStep0()`
- `testUntrackedChannels_ResetOnCheckpointLoad()`

### `10-hybrid-inference-core`

- (Contracts/types; matrix item enforcing “final chunk” is in `11-*`.)

### `11-hiveswiftagents-prebuilt`

- `testAgentsMessagesReducer_RemoveAll_UsesLastMarker()`
- `testAgentsCompaction_TrimsToBudget_WithoutMutatingMessages()`
- `testAgentsModelStream_MissingFinalFails()`
- `testAgentsToolApproval_InterruptsAndResumes()`
- `testAgentsToolExecute_AppendsToolMessageWithDeterministicID()`

### `12-conduit-adapter`

- (No spec matrix items; adapter behavior is indirectly exercised by `11-*`.)

### `13-docs-examples-hardening`

- (No spec matrix items; closure against `HIVE_SPEC.md` §18.)
