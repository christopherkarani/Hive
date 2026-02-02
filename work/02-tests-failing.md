Prompt:
Goal: Add failing Swift Testing tests covering required §17.2 behaviors and preflight validations.
Task BreakDown
- Add tests for messages reducer: removeAll last marker wins; delete-by-id fails if missing; duplicate IDs replace earlier.
- Add tests for compaction: trims without mutating messages.
- Add tests for model stream: missing final chunk fails deterministically.
- Add tests for tool approval: interrupt/resume path; tool execute appends tool message deterministic ID.
- Add preflight failure tests: missing model client, missing tool registry, invalid compaction options.
- Ensure tests fail before implementation.
Expected Output:
- New Swift Testing suites with failing tests in SwiftAgents repo.
Constraints:
- Use Swift Testing only; deterministic assertions.
