# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

All source lives under `libs/hive/`. The root Package.swift points into that directory.

```sh
# Build everything (from repo root)
swift build

# Run all tests
swift test

# Run a single test target
swift test --filter HiveCoreTests
swift test --filter HiveDSLTests
swift test --filter HiveConduitTests
swift test --filter HiveCheckpointWaxTests
swift test --filter HiveRAGWaxTests

# Run the example graph
swift run HiveTinyGraphExample
```

Swift 6.2 with strict concurrency. Platforms: iOS 26+ / macOS 26+.

## Architecture

Hive is a deterministic graph runtime for agent workflows, inspired by LangGraph's channel/reducer/superstep model. The normative spec is in `HIVE_SPEC.md`.

### Module Dependency Graph

```
HiveCore  (zero external deps)
  ├── HiveDSL         (result-builder workflow DSL)
  ├── HiveConduit      (Conduit model client adapter)
  ├── HiveCheckpointWax (Wax-backed checkpoint store)
  └── HiveRAGWax       (Wax-backed RAG snippets, depends on HiveDSL)

Hive  (umbrella: re-exports HiveCore + HiveDSL + HiveConduit + HiveCheckpointWax)
```

External dependencies: `Conduit` (LLM provider abstraction), `Wax` (on-device vector store).

### Execution Model (BSP Supersteps)

1. **Schema** (`HiveSchema` protocol) declares typed channels with reducers, scopes, and codecs
2. **Graph** is built via `HiveGraphBuilder` (or `Workflow` DSL) and compiled into `CompiledHiveGraph`
3. **Runtime** (`HiveRuntime` actor) executes the graph in deterministic supersteps:
   - Each step runs all frontier tasks concurrently
   - Writes are collected and committed atomically after all tasks complete
   - Reducers merge multiple writes to the same channel deterministically (lexicographic node ordering)
   - Next frontier is computed from static edges, routers, joins, and spawned tasks
4. **Events** stream via `AsyncThrowingStream<HiveEvent, Error>` with backpressure support

### Key Types and Their Roles

| Type | Role |
|------|------|
| `HiveSchema` | Protocol defining channels and input mapping |
| `HiveChannelSpec` | Channel metadata: scope (global/taskLocal), reducer, persistence, codec |
| `HiveChannelKey<Schema, Value>` | Typed key for reading/writing channels |
| `HiveGraphBuilder` | Imperative graph construction and compilation |
| `CompiledHiveGraph` | Validated, immutable graph ready for execution |
| `HiveRuntime` | Actor that runs the superstep loop |
| `HiveNodeInput` / `HiveNodeOutput` | Node execution contract (reads store, returns writes + next + spawn + interrupt) |
| `HiveGlobalStore` | Snapshot store for global-scoped channels |
| `HiveTaskLocalStore` | Per-task overlay for fan-out (Send pattern) |
| `HiveStoreView` | Unified read view combining global + task-local stores |
| `HiveRunHandle` | Handle with event stream + outcome task |
| `HiveEnvironment` | Injected context: clock, logger, model client, tools, checkpoint store |

### Interrupt / Resume Flow

Nodes can return `HiveInterruptRequest` in their output. The runtime pauses, saves a checkpoint, and returns `HiveRunOutcome.interrupted`. Resume via `runtime.resume(threadID:interruptID:payload:options:)` which loads the checkpoint and continues from the interrupted step.

### HiveDSL (Result Builder API)

`Workflow`, `Node`, `Edge`, `Join`, `Chain`, `Branch` are DSL components using `@WorkflowBuilder`. Nodes are marked as start nodes via `.start()`. The DSL compiles down to `CompiledHiveGraph` via `HiveGraphBuilder`.

### Macros

Macros are not currently included in this package build.

## Testing Conventions

- Uses Swift Testing framework (`import Testing`, `@Test`)
- Each test defines an inline `enum Schema: HiveSchema` with the exact channels needed
- Helper patterns: `TestClock` (noop), `TestLogger` (noop), `makeEnvironment()`, `collectEvents()` for draining event streams
- Tests verify determinism by asserting exact event ordering and store contents

## Key Conventions

- All public types are `Sendable`; the runtime is an `actor`
- Routers are synchronous (`@Sendable (HiveStoreView<Schema>) -> HiveNext`)
- Node IDs must not contain `:` or `+` (reserved for join edge canonical IDs)
- Channel IDs, node orderings, and write application all use lexicographic ordering for determinism
- Codecs are optional per channel; when present, used for checkpoint serialization and debug payload hashing
- Source paths use `libs/hive/Sources/<Module>/` and `libs/hive/Tests/<Module>Tests/`

## Agent Routing Protocol

When delegating tasks to agents, follow this decision tree:

```
TASK RECEIVED
│
├─ Is it about spec interpretation or "does the spec allow X?"
│  └─→ hive-spec-oracle (read-only, returns verdict)
│
├─ Is it a test-first task (TDD red phase)?
│  └─→ hive-test-writer (writes failing test)
│       └─ then route implementation to domain agent below
│
├─ Which module does it touch?
│  ├─ HiveCore/Runtime/ or HiveRuntime.swift
│  │  └─→ hive-runtime-dev (opus, most complex module)
│  │
│  ├─ HiveCore/Schema/ or HiveCore/Store/
│  │  └─→ hive-schema-store-dev (sonnet)
│  │
│  ├─ HiveDSL/
│  │  └─→ hive-dsl-dev (sonnet)
│  │
│  ├─ HiveConduit, HiveCheckpointWax, HiveRAGWax
│  │  └─→ implementer (global agent, sonnet — adapter modules are thin)
│  │
│  └─ Unclear / cross-cutting
│     └─→ context-builder first → then re-route
│
├─ Is it a code review?
│  └─→ swift-code-reviewer (global) + hive-spec-oracle (project)
│       (run in parallel, merge findings)
│
├─ Does it need building/debugging?
│  └─→ swift-debug-agent (global, has XcodeBuild MCP)
│
└─ Is it documentation?
   └─→ documenter (global, haiku)
```

**Context handoff template** (use when delegating to agents):
```
## Context for [agent-name]

**Task:** [one-line description]
**Spec Verdict:** [from oracle, if consulted]
**Failing Test:** [from test-writer, if TDD]
**Files to Modify:** [specific paths]
**Constraints:** [from previous agents]
**Acceptance Criteria:** [from user or test assertions]
```

## Common Tasks → Agent Mapping

| Task | Primary Agent | Support Agent | Skill |
|------|--------------|---------------|-------|
| Add new reducer | hive-schema-store-dev | hive-spec-oracle | /hive-test |
| Add new node type | hive-dsl-dev | hive-test-writer | /hive-workflow |
| Fix runtime bug | hive-runtime-dev | swift-debug-agent | — |
| Add checkpoint feature | hive-runtime-dev | hive-spec-oracle | /hive-verify |
| New channel type | hive-schema-store-dev | hive-spec-oracle | /hive-schema |
| DSL enhancement | hive-dsl-dev | hive-test-writer | /hive-workflow |
| Code review | swift-code-reviewer | hive-spec-oracle | /hive-verify |
| New integration adapter | implementer (global) | hive-test-writer | /hive-test |

## Hive-Specific Pitfalls

- **Determinism breaks silently.** Any change to node ordering, reducer application, or frontier computation can break determinism. Always test with multi-writer scenarios and assert exact event sequences.
- **HiveRuntime.swift is ~90KB.** Read the specific section you need (MARK sections), don't try to grok the whole file.
- **Node IDs must not contain `:` or `+`.** These are reserved for join edge canonical IDs. Validation exists in graph compilation but not at runtime.
- **Routers are synchronous.** `@Sendable (HiveStoreView<Schema>) -> HiveNext` — don't make them async or they'll break the step algorithm.
- **Task-local stores overlay global.** Reads from `HiveStoreView` check task-local first, then fall through to global. Writes to task-local channels from non-task contexts are errors.
- **Checkpoint atomicity.** If `checkpointStore.save()` throws, the step MUST NOT commit. This is a spec MUST requirement (§12).
- **Codec presence affects persistence.** Channels without codecs cannot be checkpointed. If a test needs checkpoint/resume, ensure all relevant channels have codecs.

## TDD Workflow with Hive Agents

1. **Spec Check** — Invoke `hive-spec-oracle` or `/hive-verify` to confirm the feature is spec-compliant
2. **Red** — Invoke `hive-test-writer` or `/hive-test` to write failing tests
3. **Green** — Route to the domain agent (hive-runtime-dev, hive-schema-store-dev, or hive-dsl-dev)
4. **Build** — Run `swift build` and `swift test --filter <target>` via swift-debug-agent if errors occur
5. **Review** — Invoke `swift-code-reviewer` + `hive-spec-oracle` in parallel
6. **Iterate** — Fix review findings, re-run tests

## Conflict Resolution

| Conflict | Resolution |
|----------|------------|
| Spec oracle says VIOLATION, dev agent disagrees | **Spec oracle wins.** The spec is normative. |
| Two agents modify the same file | **Sequential execution.** Never run two write-agents on the same file in parallel. |
| Test writer and implementer disagree on behavior | **Test wins** (TDD). Implementation must satisfy the test. |
| Code reviewer flags intentional design choice | **Escalate to user.** Present both perspectives. |
| Cross-module change (Schema + Runtime + DSL) | **Sequence by dependency:** Schema → Runtime → DSL. Each runs after the previous completes. |
