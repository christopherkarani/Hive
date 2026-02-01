# Hive v1 — Codex Implementation Plans

These documents decompose `HIVE_SPEC.md` (normative) into discrete, end-to-end tasks that a Codex coding agent can implement.

## How to use

1. Pick the next subfolder in **Execution order**.
2. Open its `prompt.md` and paste it into a Codex coding agent.
3. The agent should follow `plan.md` and make the required tests pass.
4. Use `plans/hive-v1/PARITY.md` to confirm the `HIVE_SPEC.md` §17.2 test matrix is fully covered.

## Execution order

0. `00-scaffold` — create `libs/hive` SwiftPM workspace + targets, and a minimal test harness
1. `01-schema-channels-codecs-writes` — schema/channel model + codecs + type-erased specs + writes
2. `02-reducers-update-policy` — reducers + updatePolicy semantics pinned by tests
3. `03-store-model-fingerprint` — global store, task-local overlay, store view, initialCache, task-local fingerprint
4. `04-graph-builder-compilation-versioning` — graph builder/compile + join/router IDs + output projection + schema/graph version hashing
5. `05-runtime-step-algorithm-core` — runtime public API + superstep algorithm + ordering + routing semantics (no checkpointing yet)
6. `06-events-streaming-backpressure` — event model, ordering, debug payloads, token streaming determinism, backpressure rules
7. `07-errors-retries-cancellation-limits` — error taxonomy, step atomicity, retry backoff determinism, cancellation, maxSteps
8. `08-interrupt-resume-external-writes` — interrupt selection + resume visibility + external writes
9. `09-checkpointing-wax` — snapshot contents + store contract + version mismatch + encode/decode failure timing + Wax store
10. `10-hybrid-inference-core` — canonical chat/tool types, model client contract, tool registry, routing hints
11. `11-hiveswiftagents-prebuilt` — prebuilt agents schema + reducer + nodes + wiring + facade behavior
12. `12-conduit-adapter` — Conduit model client adapter + event mapping
13. `13-docs-examples-hardening` — docs, examples, and “definition of done” closure

## Spec parity map (authoritative → plan)

- `HIVE_SPEC.md` §6–§8 → `01-*`, `02-*`, `03-*`
- `HIVE_SPEC.md` §9 → `04-*`
- `HIVE_SPEC.md` §10 → `05-*` (+ `06-*` for eventing, `08-*` for externals)
- `HIVE_SPEC.md` §11 → `07-*`
- `HIVE_SPEC.md` §12 → `08-*` (+ `09-*` for persisted resume)
- `HIVE_SPEC.md` §13 → `06-*`
- `HIVE_SPEC.md` §14 → `09-*` (+ `04-*` for version hashing)
- `HIVE_SPEC.md` §15 → `10-*`
- `HIVE_SPEC.md` §16 → `11-*`
- `HIVE_SPEC.md` §17 → every plan (each plan must add/enable its required tests)
- `HIVE_SPEC.md` §18 → `13-*`

## Non-negotiables (apply to every plan)

- `HIVE_SPEC.md` is normative; if `HIVE_V1_PLAN.md` differs, the spec wins.
- Tests MUST use the Swift Testing framework.
- Anything that affects observable results (store contents, checkpoints, event ordering, hashes) MUST be deterministic.
