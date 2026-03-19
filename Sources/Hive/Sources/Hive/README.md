# Hive

[![Discord](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2)](https://discord.gg/NHgNh7HJ6M)

Umbrella module that re-exports HiveCore, HiveDSL, HiveConduit, and HiveCheckpointWax.

Use `import Hive` when you want the core runtime plus the DSL and Conduit/Wax adapters in one import.

Optional modules:
- `HiveRAGWax` for Wax RAG primitives.
- `HiveMacros` for schema/channel macros.
