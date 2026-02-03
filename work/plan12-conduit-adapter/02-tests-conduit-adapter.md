Prompt:
You are the Test-First Agent for Plan 12 (Conduit adapter). Write failing tests that define the expected Conduit-backed streaming behavior and event emission.
Goal:
Establish deterministic Swift Testing tests that codify Hive’s streaming and event semantics before implementation.
Task Breakdown:
- Review the context report from Task 01 and `HIVE_SPEC.md` §15.2.
- Identify the test module location for HiveConduit (likely under `Tests/`).
- Create a stubbed Conduit client that can simulate:
- A successful token stream with a clear end.
- A failure mid-stream (error propagation).
- Write Swift Testing tests that assert:
- Events are emitted in order: `modelInvocationStarted` → tokens → `modelInvocationFinished`.
- Exactly one terminal `.final(HiveChatResponse)` chunk appears on successful completion.
- Error paths do not emit a final chunk but do emit a finish event (if spec requires).
- Keep tests deterministic and minimal; avoid real network or timeouts.
Expected Output:
- New failing tests (Swift Testing) that assert streaming order, final chunk semantics, and event emission behavior.
