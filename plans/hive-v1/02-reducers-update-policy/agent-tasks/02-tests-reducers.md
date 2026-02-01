Prompt:
You are adding Swift Testing coverage for Plan 02 reducer behavior. Focus on deterministic ordering and append semantics. Keep tests small and deterministic.

Goal:
Add reducer tests for dictionaryMerge ordering, append, and appendNonNil.

Task BreakDown:
- Add tests under `libs/hive/Tests/HiveCoreTests/Reducers/`.
- Verify `dictionaryMerge(valueReducer:)` processes keys in ascending UTF-8 lexicographic order (use a reducer that records order).
- Verify `append` preserves element order across updates.
- Verify `appendNonNil` drops nils but preserves order of non-nil elements.
- Use the Swift Testing framework only.
