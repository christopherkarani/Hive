# Troubleshooting

## Compile-Time Graph Errors

### `HiveCompilationError.startEmpty`
- Cause: graph has no start nodes.
- Fix: set start nodes in `HiveGraphBuilder(start:)`.

### `HiveCompilationError.unknown*`
- Cause: graph references a node ID that was never added.
- Fix: add the node or correct the edge/router/join endpoint.

### `HiveCompilationError.duplicateNodeID` / `duplicateRouter`
- Cause: added the same node or router twice.
- Fix: ensure unique IDs and one router per source node.

## Runtime Before Step 0

### Missing codec or registry init failure
- Cause: checkpointed channels without codecs.
- Fix: add codecs for all checkpointed global and task-local channels.

### Checkpoint load fails
- Cause: schema, graph, channel fingerprint, or join barrier shape changed since the checkpoint was written.
- Fix: migrate or discard old checkpoints; keep codec IDs and channel types stable.

## Runtime During a Step

### Unknown channel write
- Cause: node wrote to a channel ID not present in the schema.
- Fix: define the channel spec and use `HiveChannelKey` consistently.

### `updatePolicyViolation`
- Cause: multiple writes to a `.single` channel within a step.
- Fix: use `.multi`, or aggregate earlier to one write.

### Reducer throws
- Cause: reducer is not total or depends on invalid input state.
- Fix: make reducer behavior total and deterministic.

### Checkpoint save fails
- Cause: encode errors or backend store failure.
- Fix: ensure checkpointed values encode with their codecs and inspect the store error.

## Event Drift
- Cause: nondeterministic metadata, small event buffer capacity, or live stream ordering.
- Fix: use stable metadata and `HiveRunOptions(deterministicStreamBuffering: true)` for golden traces.
