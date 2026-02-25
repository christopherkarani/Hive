# Swarm -> Hive Adapter Execution Prompt

```text
You are acting as a principal Swift engineer in the Swarm repository.

Mission:
Build a production-grade Swarm -> Hive adapter so Swarm can use Hive as its graph runtime with deterministic behavior, durable checkpoint semantics, and stable orchestration contracts.

Context:
- Runtime backend: Hive (Swift 6.2).
- SwiftAgents is deprecated and must not be referenced.
- Keep changes atomic and test-backed.
- Do not edit plan documents.
- Prioritize runtime semantics correctness over API sugar.

What to do:

1) Discover and document current Swarm runtime contract
- Identify Swarm orchestration interfaces for:
  - start/run
  - resume/interrupt
  - cancel
  - external writes / injected state updates
  - state snapshot / getState
  - fork/replay
  - event streaming
  - run options (checkpoint policy, streaming mode, concurrency, max steps)
- Produce a contract matrix: Swarm contract field -> Hive API mapping -> status (implemented/partial/missing).

2) Implement Swarm->Hive adapter layer
- Add adapter types to map Swarm runtime requests to HiveRuntime APIs:
  - run
  - resume
  - applyExternalWrites
  - getState
  - fork
- Add strict option mapping with explicit defaults and validation.
- Add canonical translation for outcomes/events/errors/cancellation into Swarm contract types.
- Ensure no silent fallback behavior for unsupported options; fail loudly and typed.

3) Enforce semantics parity and determinism
- Cancellation during checkpoint persistence must resolve deterministically as cancelled outcome semantics (not ambiguous thrown error behavior).
- Interrupt/resume semantics must preserve pending interruption rules.
- External writes must preserve frontier + increment step index behavior.
- Event ordering must be deterministic and stable for replay assertions.
- Run identity/checkpoint identity behavior must remain consistent across cold-start resume paths.

4) Add contract tests (required)
- Unit tests:
  - option mapping
  - error mapping
  - event mapping
  - duplicate tool/runtime registration edge handling if present in Swarm interfaces
- Integration tests:
  - run happy path
  - interrupt -> resume
  - cancel during checkpoint save
  - external writes + next run continuation
  - fork from checkpoint
  - streaming mode variants
- Negative tests:
  - malformed state/checkpoint mismatch
  - unsupported option combos
  - missing required store/config
- Add assertions for both outcome values and event sequence.

5) Add soak + replay determinism suite
- Build seeded orchestration workload test:
  - long-running loop
  - controlled interruptions/resumes
  - periodic external writes
- Run same seeded workload multiple times and compare:
  - normalized event transcript hash
  - final state hash
- Fail on divergence and print minimal diff for first mismatch.

6) CI/stability
- Add a stable test invocation path for adapter tests (isolated runs if needed) so PR gating is reliable even if monolithic swift test is flaky.
- Keep full test job plus deterministic subset job.

7) Deliverables
- Contract matrix with evidence (files/tests).
- Ranked backlog of remaining work:
  - severity
  - user impact
  - implementation complexity
  - recommended order
- Change summary with exact file references.
- Test results:
  - targeted tests
  - full suite path
  - soak/replay results
  - unresolved risks.

Quality bar:
- Swift 6.2 idioms.
- Deterministic runtime semantics.
- No silent data loss.
- No behavior regressions.
- Adapter should make Hive feel like native Swarm runtime.
```
