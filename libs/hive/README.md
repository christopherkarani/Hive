# Hive (Swift Package)

Hive is a Swift graph runtime with optional adapters for agent orchestration, inference, and RAG.

## Modules
- `Hive` — umbrella module for the full stack (one import).
- `HiveCore` — schema and core runtime primitives.
- `HiveConduit` — Conduit model client adapter.
- `HiveCheckpointWax` — Wax-backed checkpoint store.

## Usage
- Full stack: `import Hive`
- Minimal core: `import HiveCore`

## Development
- Build: `make build`
- Test: `make test`
- Format: `make format` (skips if `swiftformat` is not installed)
- Lint: `make lint` (skips if `swiftlint` is not installed)
