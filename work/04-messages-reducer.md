Prompt:
Goal: Implement messages reducer per §16.3 with deterministic behavior.
Task BreakDown
- Enforce last `removeAll` wins.
- Delete-by-id should fail if missing.
- Rightmost duplicate IDs replace earlier messages.
- Emit only normal messages (strip internal markers).
- Verify against tests.
Expected Output:
- Reducer implementation wired into `messages` channel spec.
Constraints:
- Must match §16.3 semantics exactly.
