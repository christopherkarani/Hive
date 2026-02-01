Prompt:
You are implementing store types for Plan 03: `HiveGlobalStore`, `HiveTaskLocalStore`, and `HiveStoreView` per `HIVE_SPEC.md` §7.2.

Goal:
Implement store composition rules and read semantics (global + taskLocal + initialCache fallback), including unknown channel and scope mismatch errors.

Task BreakDown:
- Define public APIs for the three store types (Swift-first, minimal, safe)
- Implement global store initialization after initialCache
- Implement taskLocal overlay storage (no global persistence)
- Implement store view read semantics and validation
- Ensure errors match `HiveRuntimeError` per spec
- Note any dependencies on registry or initialCache design
