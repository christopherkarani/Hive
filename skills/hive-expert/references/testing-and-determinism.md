# Testing + Determinism

## What to Test (In Order)
1. **Schema correctness**
   - Specs: reducer + updatePolicy + persistence + codec rules.
   - Initial values and `inputWrites` behavior.
1. **Graph compilation**
   - Unknown node IDs, duplicate node IDs, join parent validity, router uniqueness.
1. **Runtime semantics**
   - Superstep ordering (frontier → run → commit → next frontier).
   - Write merge semantics (reducer behavior + updatePolicy failures).
   - Join barrier behavior.
   - Interrupt selection and resume delivery.
1. **Deterministic observability**
   - Event stream ordering.
   - Stable hashes/redactions (when applicable).

## Golden Tests
When you need reproducible traces:
- Enable `HiveRunOptions(deterministicTokenStreaming: true)`.
- Consider increasing `eventBufferCapacity` to avoid token/debug drops.
- Prefer asserting against:
  - `HiveRunOutcome` + projected outputs
  - event kinds in order (avoid matching on timing-dependent metadata)

## Common Determinism Pitfalls
- Reducer uses unordered iteration (dictionary traversal without sorting).
- Node writes include timestamps/randomness without seeding.
- Tool definitions differ between runs (e.g., unstable JSON schema strings).

