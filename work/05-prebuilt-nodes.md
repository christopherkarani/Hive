Prompt:
Goal: Implement prebuilt nodes: preModel compaction, model, tools, toolExecute per §16.4.
Task BreakDown
- Implement compaction node (default if no custom).
- Model node: build request, sort tools, select model client, require exactly one final chunk, set assistant msg, pendingToolCalls, finalAnswer, clear llmInputMessages.
- Tools node: sort calls, apply approval policy, interrupt/resume; on reject append system message.
- ToolExecute: invoke registry, append `.tool` message with `tool:<callID>` ID, route to model.
- Ensure deterministic ordering and IDs.
Expected Output:
- Node implementations in `Sources/HiveSwiftAgents/` with deterministic behavior.
Constraints:
- Follow §16.4 exactly; no mutation of `messages` in compaction.
