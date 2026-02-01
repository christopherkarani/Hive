Prompt:
You are writing Swift Testing tests for Plan 03. Use `HIVE_SPEC.md` §17.2 fixtures.

Goal:
Add failing tests first, then outline expected assertions for store semantics, initialCache order, and fingerprinting.

Task BreakDown:
- Add Swift Testing tests:
  - `testInitialCache_EvaluatedOnceInLexOrder()`
  - `testTaskLocalFingerprint_EmptyGolden()`
  - `testTaskLocalFingerprintEncodeFailure_Deterministic()`
- Define fixtures and golden values from spec
- Describe expected behaviors and failure modes
- Identify any test helpers or mock codecs needed
- Note any gaps if spec fixtures are missing in repo
