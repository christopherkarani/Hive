Prompt:
You are the Code Review Agent for Plan 12 (Conduit adapter). Review the implementation and tests for correctness, type safety, API clarity, and spec compliance.
Goal:
Validate that the Conduit adapter matches the plan and spec, with no correctness or concurrency regressions.
Task Breakdown:
- Review new/changed files from Tasks 02 and 03.
- Verify §15.2 semantics: exactly one terminal `.final(HiveChatResponse)` chunk on success.
- Confirm event ordering and emission for start/token/finish.
- Check Conduit→canonical conversions for correctness and minimal API leakage.
- Assess Sendable and structured concurrency correctness; flag any shared mutable state.
- Identify missing tests or edge cases (cancellation, early errors, empty streams).
Expected Output:
- A prioritized review report with concrete findings and file/line references, plus any test gaps.
