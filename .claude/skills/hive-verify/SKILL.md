---
name: hive-verify
description: "Run spec compliance checks on a Hive component. Verifies code against HIVE_SPEC.md normative requirements."
user-invocable: true
argument-hint: "[file-or-feature]"
---

# Hive Spec Compliance Verification

Verify that a Hive component or feature implementation complies with HIVE_SPEC.md normative requirements.

## Verification Process

### Step 1: Read Target Files
Read the file(s) or feature area to be verified.

### Step 2: Read Relevant Spec Sections
Read HIVE_SPEC.md and identify which sections apply:
- §6 — Schema and Channels
- §7 — Store Model (Global, TaskLocal, StoreView)
- §8 — Reducers
- §9 — Graph Builder and Compilation
- §10 — Runtime Configuration
- §11 — Step Algorithm
- §12 — Checkpointing
- §13 — Interrupt and Resume
- §14 — Events and Streaming
- §15 — Error Handling
- §16 — Concurrency Model

### Step 3: Check Each Requirement
For each applicable section, check against the RFC 2119 keyword classification:
- **MUST** — Absolute requirement. Violation = non-compliant.
- **SHOULD** — Recommended. Deviation requires justification.
- **MAY** — Optional. Implementation choice.

### Step 4: Generate Compliance Report

Output format for each requirement checked:

```
§[section] — [MUST/SHOULD/MAY] — [requirement text summary]
Status: ✅ PASS | ⚠️ DEVIATION | ❌ VIOLATION
Evidence: [line number or code reference]
Notes: [explanation if DEVIATION or VIOLATION]
```

## Critical MUST Requirements to Always Check

1. **Deterministic ordering** — Writes applied in lexicographic node ID order (§11)
2. **Atomic commits** — All frontier task writes committed together (§11)
3. **Checkpoint atomicity** — If save fails, step must not commit (§12)
4. **Single-writer per thread** — Serialized execution within a thread (§16)
5. **Reducer determinism** — Same inputs always produce same output (§8)
6. **Channel scope** — Global vs taskLocal correctly enforced (§6, §7)
7. **Router synchrony** — Routers must be synchronous (§9)
8. **Node ID constraints** — No `:` or `+` in node IDs (§9)
9. **Event ordering** — Events emitted in deterministic step order (§14)
10. **Input mapping** — `mapInputs` applied as synthetic step 0 writes (§10)

## Summary Format

```
## Compliance Report: [target]

Sections checked: §X, §Y, §Z
Requirements verified: N
  ✅ PASS: N
  ⚠️ DEVIATION: N
  ❌ VIOLATION: N

[Details for each non-passing requirement]

Overall: COMPLIANT / NON-COMPLIANT
```
