# Hive (Swift Package)

Hive is a deterministic Swift graph runtime with optional adapters for inference, tools, and checkpointing.

## Mental Model (60s)
- Channels are typed storage slots declared in a `HiveSchema` (global or task-local).
- Reducers merge multiple writes to the same channel during a superstep.
- Supersteps execute the current frontier of tasks, then commit writes and build the next frontier.
- Send and join: tasks send writes and next-node decisions; join edges wait for all parents before scheduling a target.
- Checkpoint/resume captures global state + frontier + join barriers so a thread can resume later.

## Modules
- `Hive` — umbrella module for HiveCore + adapters (one import).
- `HiveCore` — schema, graph builder, runtime, and core types.
- `HiveConduit` — Conduit-backed `HiveModelClient` adapter.
- `HiveCheckpointWax` — Wax-backed checkpoint store.
- SwiftAgents integration (separate package): `HiveSwiftAgents` tool registry adapter.

## Start Here
- `Sources/HiveCore/README.md` for the mental model and core API.
- `Sources/HiveConduit/README.md` for Conduit model wiring.
- `Sources/HiveCheckpointWax/README.md` for checkpoint storage.
- `Sources/HiveSwiftAgents/README.md` for SwiftAgents integration (requires SwiftAgents package).

## Examples
- `Examples/README.md` for runnable SwiftPM examples.

## Usage
- Full stack: `import Hive`
- Minimal core: `import HiveCore`

## Development
- Build: `make build`
- Test: `make test`
- Format: `make format` (skips if `swiftformat` is not installed)
- Lint: `make lint` (skips if `swiftlint` is not installed)
- Release checklist: `../../docs/hive-release-checklist.md`
