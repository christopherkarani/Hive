Prompt:
Fix the missing Git LFS object in the upstream TiktokenSwift dependency (or an internal mirror) and pin Wax to a validated commit/tag.

Goal:
Restore SwiftPM checkout reliability for TiktokenSwift without changing Wax’s public API or behavior.

Task BreakDown
- Confirm the missing LFS object for commit `661c349…` by testing a clean clone with Git LFS enabled.
- If upstream maintainer is available, open an issue/PR requesting re-push of missing LFS objects.
- If upstream is unresponsive, create an internal fork/mirror and push the missing LFS objects there.
- Update `rag/Wax/Package.swift` to pin to the fixed commit/tag in the fork.
- Run `swift package resolve` and `swift test` for `rag/Wax`, then `libs/hive`.
- Document the pin rationale and verification date in `docs/tiktoken-issues.md`.
