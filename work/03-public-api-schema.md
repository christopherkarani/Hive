Prompt:
Goal: Implement public API types and Schema channel specs per §16.1–§16.2.
Task BreakDown
- Define `HiveAgentsToolApprovalPolicy`, `HiveAgents`, `HiveTokenizer`, `HiveCompactionPolicy`, `HiveAgentsContext`, `HiveAgentsRuntime`.
- Implement `HiveAgents.Schema` channelSpecs for messages, pendingToolCalls, finalAnswer, llmInputMessages, currentToolCall.
- Implement inputWrites: append deterministic user message ID; set `finalAnswer = nil`.
- Add doc comments for public APIs.
Expected Output:
- Public API and Schema implemented in `Sources/HiveSwiftAgents/`.
Constraints:
- Conform to Swift 6.2 strict concurrency; add doc comments.
