Prompt:
Make TiktokenSwift optional so Hive can build/test without the dependency unless explicitly enabled.

Goal:
Allow default Hive builds to succeed even when TiktokenSwift cannot be fetched, while preserving token counting when enabled.

Task BreakDown
- Add a SwiftPM trait/feature in `rag/Wax/Package.swift` (e.g., `TiktokenSupport`).
- Split the `Wax` target into a base target and a `WaxTiktoken` target gated by the trait.
- Update `TokenCounter` to live in the gated target; ensure APIs that require it are only compiled when enabled.
- Adjust tests so Tiktoken-dependent tests run only when the feature is enabled.
- Document the feature flag and its default behavior.
- Verify `swift test` passes for `libs/hive` with the feature off; verify optional path when enabled.
