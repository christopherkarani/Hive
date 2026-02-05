# HiveDSL Quirks and Guarantees

## Branch
- `Branch(from:)` must include a default case (`.default { ... }` / `.otherwise { ... }`); compilation throws if missing.
- Branch compiles into a router; default is required to avoid “silent fallthrough” errors.

## Chain
- `Chain` must start with `.start("Node")` before any `.then("Next")`; compilation throws if missing.

## Effects Merge Rules
When using `Effects { ... }`:
- `writes` are concatenated in order.
- `next` is **last-write-wins** (e.g., last `GoTo(...)` wins).
- `interrupt` is **last-write-wins** (last `Interrupt(...)` wins).
- Spawns are appended in order.

Design implication:
- Treat `Effects` as a small “transaction builder”; ensure you don’t accidentally override `next`/`interrupt` later in the block.

## ModelTurn
- Tool policy matters:
  - `.environment` pulls from `HiveEnvironment.tools` (must be non-nil).
  - `.explicit([...])` bypasses environment tools.
- If no model client is available, model turns fail at runtime (provide `environment.model` or `environment.modelRouter`).

## WorkflowPatch / Diff
- Patch operations like `insertProbe` rewrite **static edges only**.
- Routers and join edges are not rewritten by edge-rewriting patches.

