Prompt:
Harden docs and tests around deterministic traces, checkpoint/resume parity, and Send/join behavior. If §18 items are not pinned by tests, add tests or produce a follow-up plan.

Goal:
Ensure Definition of Done items are verifiably covered by tests and documented.

Task Breakdown:
- Audit current tests and golden fixtures for determinism and trace coverage.
- Verify checkpoint/resume parity tests exist and are deterministic.
- Verify Send/fan-out and join edge behavior is covered by tests.
- If gaps exist, write failing tests first using Swift Testing, then implement or produce a follow-up gap plan.
- Document how to update golden fixtures intentionally.

Expected Output:
- Updated test coverage or a clear gap plan for missing §18 items.
- Documentation that explains golden fixtures and deterministic trace expectations.
