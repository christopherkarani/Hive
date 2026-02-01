Prompt:
You are implementing Plan 02 standard reducers for HiveCore. Keep it pure and deterministic. Use HIVE_SPEC.md section 8 for semantics. Do not touch runtime or commit logic.

Goal:
Add standard reducer factories to HiveReducer with correct, spec-aligned behavior.

Task BreakDown:
- Review HIVE_SPEC.md section 8 reducer semantics and updatePolicy notes.
- Implement standard reducers in `libs/hive/Sources/HiveCore/Schema/HiveReducer+Standard.swift` (or adjacent file if already exists).
- Ensure reducers are pure and do not depend on unordered collection iteration.
- Keep public API minimal and Swifty; prefer value types and compile-time safety.
