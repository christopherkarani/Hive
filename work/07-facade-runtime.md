Prompt:
Goal: Implement facade behavior and runtime preflight validation per §16.6.
Task BreakDown
- Implement `HiveAgentsRuntime.sendUserMessage`.
- Implement `HiveAgentsRuntime.resumeToolApproval`.
- Ensure payloads/options for `HiveRuntime` are correct.
- Enforce preflight validation before step 0.
Expected Output:
- Facade methods + preflight checks implemented.
Constraints:
- Must fail before step 0 for invalid env per §16.1.
