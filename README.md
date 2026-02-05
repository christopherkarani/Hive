# Hive

Deterministic, Swift‑native graph runtime for agent workflows. Built for iOS/macOS, strongly typed, and designed for reproducible runs, streaming, and human‑in‑the‑loop control.

**Why Hive**
- **Deterministic by design**: stable supersteps, ordered events, and golden‑testable traces.
- **Swift‑first**: pure Swift 6.2, Swift Concurrency, type‑safe channels.
- **Agent‑ready**: tool calling, token streaming, and checkpoint/resume.
- **Apple platforms**: iOS 26+ / macOS 26+ focus.

## What You Can Build
- Agent graphs with fan‑out, joins, and tool approval gates.
- SwiftUI‑style workflows with `HiveDSL` (result builders, composable nodes/branches).
- Long‑running workflows that pause for human input and resume reliably.
- RAG‑enabled pipelines via `HiveRAGWax` (Wax recall + snippets).
- On‑device or hybrid inference pipelines with deterministic testing.

## Quickstart (SwiftPM)
Hive lives in `libs/hive` in this repo.

```sh
cd libs/hive
swift build
swift test
```

Run the tiny example graph:

```sh
swift run HiveTinyGraphExample
```

## Example (Tiny Graph)
A small graph that fans out work, waits on a join, interrupts for approval, then resumes.

```swift
import HiveCore

// Build a graph, run it, and handle interrupt/resume.
// See libs/hive/Examples/TinyGraph/main.swift for the full runnable example.
```

## Repo Layout
- `libs/hive` — Swift package (HiveCore + HiveDSL + adapters + examples)
- `HIVE_SPEC.md` — normative spec
- `docs/` — release checklist and other docs

## Status
Hive v1 is in active development. The spec is stable; APIs are still evolving.

## Learn More
- `HIVE_SPEC.md` for the full runtime spec and semantics.
- `libs/hive/README.md` for DSL examples, macros, and module‑level docs.
- `libs/hive/Examples/README.md` for runnable examples.

## Contributing
Issues and PRs are welcome. If Hive helps your work, a star makes it easier for others to find.
