# Plan 13 — Docs, examples, hardening, definition of done

## Goal

Close Hive v1 to the “definition of done” in `HIVE_SPEC.md` §18 by:

- adding minimal end-user docs for each target
- adding one or two small runnable examples (in-process, iOS/macOS oriented)
- hardening: ensure deterministic golden traces, checkpoint/resume parity, Send/join semantics, and prebuilt agent UX are documented and discoverable

## Spec anchors

- `HIVE_SPEC.md` §18 (definition of done)
- `HIVE_REVIEW.md` checklist items that are still relevant once implementation exists

## Deliverables

- `libs/hive/README.md` (high-level) plus per-target READMEs if needed
- A minimal example under `examples/` (or `libs/hive/Examples/` if you prefer) that:
  - runs a tiny graph
  - demonstrates Send/fan-out
  - demonstrates interrupt/resume
- A short “release checklist” capturing any remaining manual validation steps (e.g. Xcode build)
- Confirm `swift test` passes for all Hive targets (explicit §18 requirement).
- Confirm SwiftAgents tests pass in the SwiftAgents repo for the Hive integration.

## Work breakdown

1. Document the public API and “mental model” (channels + reducers + supersteps).
2. Add examples that exercise the most important semantics and are easy to run.
3. Ensure golden fixtures/tests are explained and easy to update intentionally.
4. Cross-check against §18.
   - If any §18 item isn’t actually pinned by tests yet (not just documented), add the missing tests or file follow-up plan(s).

## Acceptance criteria

- Documentation covers how to use HiveCore and SwiftAgents-on-Hive in a real app.
- Examples compile and run.
