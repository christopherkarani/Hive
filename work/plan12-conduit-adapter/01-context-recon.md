Prompt:
You are the Context/Research Agent for Plan 12 (Conduit adapter). Gather all relevant interfaces, existing adapters, and event/streaming expectations so downstream agents can implement safely.
Goal:
Produce a short, precise context summary of required HiveCore interfaces, event hooks, and any existing adapter patterns.
Task Breakdown:
- Read `plans/hive-v1/12-conduit-adapter/plan.md` and `HIVE_SPEC.md` §15.2.
- Read `HIVE_V1_PLAN.md` §11.2 for adapter boundary expectations.
- Locate existing model client interfaces in `libs/hive/Sources` (e.g., `HiveModelClient`, `HiveChatStreamChunk`, event hooks from Plan 06).
- Scan for any existing adapters or test harnesses in `libs/hive` or `Tests` to mirror patterns.
- Summarize key APIs, expected event ordering, and final-chunk semantics with file paths.
Expected Output:
- A concise report with file paths, interface signatures, and any constraints/edge cases that must be respected.
