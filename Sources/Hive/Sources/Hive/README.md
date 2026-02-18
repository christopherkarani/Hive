# Hive

Umbrella module that re-exports HiveCore, HiveDSL, HiveConduit, and HiveCheckpointWax.

Use `import Hive` when you want the core runtime plus the DSL and Conduit/Wax adapters in one import.

Optional modules:
- `HiveRAGWax` for Wax RAG primitives.
- SwiftAgents integration lives in the SwiftAgents package (`HiveSwiftAgents`).

Macros are not currently included in this package build.
