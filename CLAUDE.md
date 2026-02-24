# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```sh
swift build                              # Build all targets
swift test                               # Run all tests
swift test --filter HiveCoreTests        # Run a single test target
swift test --filter HiveDSLTests         # Other targets: HiveConduitTests, HiveCheckpointWaxTests,
                                         #   HiveRAGWaxTests, HiveTests
swift run HiveTinyGraphExample           # Run the example executable
```

Swift 6.2 toolchain required. Platforms: iOS 26+, macOS 26+.

## Project Structure

All source and tests live under `Sources/Hive/`:

```
Sources/Hive/
├── Sources/
│   ├── HiveCore/          # Zero-dependency core (schema, graph, runtime, store)
│   ├── HiveDSL/           # Result-builder workflow DSL (depends on HiveCore)
│   ├── HiveConduit/       # Conduit model client adapter (LLM integration)
│   ├── HiveCheckpointWax/ # Wax-backed persistent checkpoints
│   ├── HiveRAGWax/        # Wax-backed vector RAG
│   └── Hive/              # Umbrella — re-exports Core + DSL + adapters
├── Tests/
│   ├── HiveCoreTests/     # Runtime, schema, store, graph, errors, data structures
│   ├── HiveDSLTests/      # Workflow compilation, patching
│   ├── HiveConduitTests/  # Model client streaming
│   ├── HiveCheckpointWaxTests/
│   ├── HiveRAGWaxTests/
│   └── HiveTests/         # Integration tests
└── Examples/TinyGraph/    # Executable example (fan-out, join, interrupt)
```

External dependencies: `Conduit` (LLM adapter) and `Wax` (checkpoint/RAG persistence).

## Architecture

Hive executes agent workflows as **deterministic superstep graphs** using the Bulk Synchronous Parallel (BSP) model:

1. **Schema** — `HiveSchema` protocol declares typed channels with reducers, scopes, and codecs
2. **Graph** — Built via `HiveGraphBuilder` (imperative) or `Workflow<Schema> { ... }` (DSL)
3. **Runtime** — `HiveRuntime` actor executes supersteps: frontier nodes run concurrently, writes commit atomically, routers schedule next frontier
4. **Store** — `HiveGlobalStore` (shared state) + `HiveTaskLocalStore` (per-task overlay for fan-out) + `HiveStoreView` (read-only merged view for nodes)
5. **Events** — Rich `AsyncThrowingStream` of typed events for observation

### HiveCore Internals (`Sources/Hive/Sources/HiveCore/`)

| Directory | Responsibility |
|-----------|---------------|
| `Schema/` | Channel specs, channel keys, reducers, codecs, schema registry, type erasure |
| `Store/` | Global store, task-local store, store view, initial cache, fingerprinting |
| `Graph/` | Graph builder, graph description (deterministic JSON), Mermaid export, ordering, versioning |
| `Runtime/` | Superstep execution, frontier computation, event streaming, interrupts, retry, task management |
| `Checkpointing/` | Checkpoint format and store protocol |
| `HybridInference/` | Model tool loop (ReAct), inference types |
| `Memory/` | Memory store protocol, in-memory implementation |
| `DataStructures/` | Bitset, inverted index |
| `Errors/` | Runtime errors, error descriptions, checkpoint query errors |

### HiveDSL Components (`Sources/Hive/Sources/HiveDSL/`)

- `Workflow<Schema> { ... }.compile()` — Main entry point using `@resultBuilder`
- `Node("id") { ... }.start()` — Processing step (`.start()` marks entry point)
- `Edge`, `Join`, `Chain`, `Branch` — Routing primitives
- `Effects { Set(...); GoTo(...); End() }` — Write + routing DSL
- `ModelTurn` — LLM integration with tool calling and agent loops
- `SpawnEach` — Fan-out to parallel workers with task-local state

### Key Execution Flow

```
Schema defines channels → Graph compiled from DSL/builder → Runtime executes supersteps:
  1. Frontier nodes execute concurrently (lexicographic order for determinism)
  2. Writes collected, reduced, committed atomically
  3. Routers run on fresh post-commit state
  4. Next frontier scheduled
  5. Repeat until End() or Interrupt()
```

## Determinism Guarantees

Hive's core invariant: **same input → same output, same event trace**. This is achieved through:

- **Lexicographic ordering** of node execution and write application by `HiveNodeID`
- **Atomic superstep commits** — all frontier writes apply together
- **Deterministic reducers** — associative merge strategies (`.lastWriteWins()`, `.append()`, `.setUnion()`)
- **Golden tests** — graph descriptions produce immutable JSON for regression testing

When writing tests, assert exact event ordering, not just presence.

## Test Patterns

Tests use **Swift Testing** (`@Test`, `#expect`, `#require`). Key conventions:

1. **Inline schemas** — Each test file defines a minimal `HiveSchema` enum with only needed channels
2. **Build graph imperatively** — Use `HiveGraphBuilder<Schema>` for test clarity
3. **Collect events** — Drain the runtime's `AsyncThrowingStream` into an array
4. **Assert deterministic ordering** — Verify exact event sequence (superstep, task, write order)
5. **Checkpoint round-trips** — Save/load cycle verification for resumable workflows

The `HiveCoreTests` target has a compiler flag: `HIVE_V11_TRIGGERS`.

## Channel Scopes and Persistence

| Scope | Behavior |
|-------|----------|
| Global | Shared across all tasks, visible to all nodes |
| Task-local | Per-task overlay from `SpawnEach`, isolated from siblings |

| Persistence | Behavior |
|-------------|----------|
| `.checkpointed` | Saved in checkpoint snapshots |
| `.untracked` | Not included in checkpoints |
| `.ephemeral` | Reset at each superstep boundary |

## Interrupt/Resume Protocol

1. Node emits `Interrupt(payload)` → runtime saves checkpoint (store + frontier + join barriers + superstep index)
2. Resume via `runtime.resume(threadID:, interruptID:, payload:, options:)`
3. Typed `Schema.ResumePayload` available in next node via `input.run.resume`

## Specification

`HIVE_SPEC.md` is the normative source of truth for runtime behavior. Implementation follows the spec — not the other way around. Use RFC 2119 keywords (MUST/SHOULD/MAY) when referencing spec requirements.

## Claude Code Skills

Available via `/hive`, `/hive-test`, `/hive-schema`, `/hive-workflow`, `/hive-verify`. Use these for scaffolding tests, generating schemas, creating workflows, and verifying spec compliance.

## Conventions

- Swift 6.2 strict concurrency: all public types are `Sendable`
- Node IDs are strings — use lexicographically sortable names for deterministic ordering
- The `Hive` umbrella product is batteries-included; use `HiveCore` alone for minimal dependency
- Do not edit plan documents in `tasks/` or `.claude/plans/`
