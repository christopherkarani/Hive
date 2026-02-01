Prompt:
You are implementing task-local fingerprinting per `HIVE_SPEC.md` §7.3 for Plan 03. Use CryptoKit SHA-256.

Goal:
Compute canonical `HLF1` bytes and SHA-256 digest for task-local channels, with deterministic error selection.

Task BreakDown:
- Define `HiveTaskLocalFingerprint` in `libs/hive/Sources/HiveCore/Store/`
- Determine effective values (overlay or initialCache)
- Encode values using codecs for taskLocal channels
- Build canonical bytes: "HLF1" + entryCount UInt32BE + entries (idLen/id/valueLen/value), lengths UInt32BE
- Hash with SHA-256
- Implement deterministic error selection: first failing channel in lexicographic channelID order
- List tests to add (empty golden + encode failure deterministic)
