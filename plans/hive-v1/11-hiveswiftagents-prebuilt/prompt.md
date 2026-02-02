# Codex prompt — Plan 11 (SwiftAgents on Hive)

You are implementing **Plan 11** from `plans/hive-v1/11-hiveswiftagents-prebuilt/plan.md`.

## Objective

Implement the SwiftAgents-on-Hive prebuilt agent graph and facade per `HIVE_SPEC.md` §16, including messages reducer semantics, compaction behavior, and tool approval interrupt/resume flow. This work lives in the SwiftAgents repo (not in Hive).

## Read first

- `HIVE_SPEC.md` §16.1–§16.6
- `HIVE_SPEC.md` §17.2 “HiveAgents” tests listed in the plan

## Constraints

- Messages reducer semantics must match the spec exactly; pin with tests.
- Tool approval flows must be deterministic (sorted tool calls, deterministic IDs).
- Enforce §16.1 “fail before step 0” environment requirements (`modelClientMissing`, `toolRegistryMissing`, invalid compaction options).

## Commands

- `cd <SwiftAgentsRepo> && swift test`
