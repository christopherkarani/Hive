Prompt:
You are implementing the initialCache layer per Plan 03 and `HIVE_SPEC.md` §7.1. Focus only on initialCache evaluation and storage.

Goal:
Design and implement deterministic initialCache evaluation ("at most once") in lexicographic channelID order and a storage form that supports typed reads without re-running `initial()`.

Task BreakDown:
- Identify or create `HiveInitialCache` (or equivalent) in `libs/hive/Sources/HiveCore/Store/`
- Define storage that preserves value + type safety for typed reads
- Implement evaluation order: channelID lexicographic; each `initial()` evaluated exactly once
- Specify error handling requirements per spec
- List tests to add or update (initialCache only)
