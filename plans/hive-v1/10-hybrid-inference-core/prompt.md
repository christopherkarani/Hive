# Codex prompt — Plan 10 (Hybrid inference core)

You are implementing **Plan 10** from `plans/hive-v1/10-hybrid-inference-core/plan.md`.

## Objective

Add canonical chat/tool types and the `HiveModelClient` + tool registry contracts (including `Any*` type erasures used by `HiveEnvironment`) to `HiveCore` per `HIVE_SPEC.md` §15.

## Read first

- `HIVE_SPEC.md` §15.1–§15.4

## Constraints

- `HiveCore` must not import Conduit/SwiftAgents/Wax.
- Types should be Codable + Sendable where appropriate.

## Commands

- `cd libs/hive && swift test`
