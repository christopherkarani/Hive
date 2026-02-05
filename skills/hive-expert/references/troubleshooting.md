# Troubleshooting (Symptom → Cause → Fix)

## Compile-Time (Graph / DSL)

### `HiveCompilationError.startEmpty`
- Cause: graph has no start nodes.
- Fix: set start nodes in `HiveGraphBuilder(start:)` or mark a DSL node with `.start()`.

### `HiveCompilationError.unknown*` (edge/router/join endpoints)
- Cause: graph references a node ID that was never added.
- Fix: add the node or correct the ID spelling.

### `HiveCompilationError.duplicateNodeID` / `duplicateRouter`
- Cause: added the same node/router twice.
- Fix: ensure unique IDs and single router per `from` node.

### `HiveDSLCompilationError.branchDefaultMissing`
- Cause: `Branch(from:)` is missing `.default { ... }`.
- Fix: add a `.default { UseGraphEdges() }` (or equivalent).

### `HiveDSLCompilationError.chainMissingStart`
- Cause: `Chain` uses `.then(...)` before `.start(...)`.
- Fix: ensure the first link is `.start("NodeID")`.

## Runtime Before Step 0

### Missing codec errors / registry init failures
- Cause: checkpointed channels without codecs (global or task-local).
- Fix: add codecs (or use JSON codec via schema/macro defaults) for all checkpointed channels.

### Checkpoint load fails (version/fingerprint mismatch)
- Cause: schema/graph changed since checkpoint was created.
- Fix: migrate or discard old checkpoints; keep codec IDs/types stable.

## Runtime During a Step (No Commit)

### Unknown channel write
- Cause: node wrote to a channel ID not in schema.
- Fix: define the channel spec and use `HiveChannelKey` consistently.

### `updatePolicyViolation`
- Cause: multiple writes to a `.single` channel within a step.
- Fix: set `updatePolicy: .multi`, or aggregate earlier to a single write.

### Reducer throws
- Cause: reducer not total for all values (or throws for certain states).
- Fix: make reducer total/deterministic; validate inputs.

### Checkpoint save fails (when enabled)
- Cause: encode errors or backend store failure.
- Fix: ensure checkpointed values are encodable with their codecs; debug backend errors.

## Model/Tool Issues

### `modelClientMissing`
- Cause: model turn runs without `environment.model` and without a router.
- Fix: provide `AnyHiveModelClient` or `HiveModelRouter`.

### `modelStreamInvalid`
- Cause: stream missing final, multiple finals, or token after final.
- Fix: fix model adapter to satisfy the `.final` contract.

### Tool invocation errors
- Cause: invalid JSON arguments (`argumentsJSON` must be a JSON object string for some adapters), schema mismatch.
- Fix: validate tool JSON schema strings and tool argument encoding/decoding.

