Prompt:
Create minimal end-user documentation that explains Hive’s public API and mental model (channels, reducers, supersteps), plus usage of HiveCore and SwiftAgents-on-Hive. Focus on clarity and discoverability.

Goal:
Provide high-level docs that make Hive usable for new adopters and satisfy the “docs” portion of Definition of Done.

Task Breakdown:
- Review existing docs in `libs/hive/README.md` and related targets.
- Document the mental model: channels, reducers, supersteps, and how Send/join works conceptually.
- Add concise guidance for HiveCore usage in a real app.
- Add concise guidance for SwiftAgents-on-Hive integration in a real app.
- Ensure any API references are accurate and minimal.

Expected Output:
- Updated or new README content for Hive targets that explains the mental model and public API usage.
- Clear references to Send/fan-out, join semantics, and checkpoint/resume at a conceptual level.
