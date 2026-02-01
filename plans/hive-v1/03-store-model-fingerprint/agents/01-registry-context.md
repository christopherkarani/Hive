Prompt:
You are a Swift 6.2 engineer. Extract the minimal registry surface needed for Plan 03 store and fingerprint work. Use the spec anchors in `HIVE_SPEC.md` §7 and Plan 03.

Goal:
Define a minimal registry representation (types/protocols) that can validate channel existence, scope, and typeID for store reads.

Task BreakDown:
- Locate existing registry types (if any) and identify the minimal API needed for:
  - channel existence lookup by channelID
  - scope validation (global vs taskLocal)
  - typeID and codec access for taskLocal channels
- Propose the smallest additions/adjustments required for Plan 03
- List concrete file paths and symbols to implement or extend
- Call out any missing spec details or open questions
