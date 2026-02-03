# SwiftAgents → Hive Runtime Migration: Validation Addendum (Deep SwiftAgents API Review)

Date: 2026-02-03

This addendum validates and refines `plans/SWIFTAGENTS_ON_HIVE_RUNTIME_MIGRATION_PLAN.md` using deeper SwiftAgents codebase context, with the explicit requirement:

> Hive is the one and only runtime. SwiftAgents must not carry a parallel/embedded runtime implementation.

It **does not modify** the existing plan document (plan immutability). It records blockers, required corrections, and “decisions to lock” so implementation can proceed without surprises.

---

## A) SwiftAgents API Deep Dive: What Actually Matters for HiveSwiftAgents

### A.1 Tools are the only meaningful SwiftAgents→Hive contract today

The relevant SwiftAgents public ABI for Hive integration is:

- `AnyJSONTool` (`Sources/SwiftAgents/Tools/Tool.swift`)
  - `name`, `description`, `parameters: [ToolParameter]`
  - `execute(arguments: [String: SendableValue]) async throws -> SendableValue`
- `ToolParameter` and `ToolSchema`
- `ToolRegistry` (an `actor`)
  - `execute(toolNamed:arguments:agent:context:hooks:) async throws -> SendableValue`
  - This execution path includes **argument normalization** and **guardrail execution**.
- `SendableValue` (canonical JSON-ish value used across SwiftAgents)

Everything else (ReActAgent, PlanAndExecute, orchestration) is *not* currently consumed by `HiveSwiftAgents` and does not block “Hive as the runtime” for the prebuilt Hive graph.

### A.2 Critical implication: the Hive tool adapter must preserve ToolRegistry semantics

SwiftAgents tool execution is not “just call `tool.execute`”:
- `ToolRegistry.execute` normalizes arguments (defaults + coercion) and runs guardrails.
- A Hive tool adapter that bypasses `ToolRegistry.execute` changes behavior and will be a correctness regression for any user relying on those semantics.

Therefore, the `HiveSwiftAgents` → `HiveToolRegistry` bridge must be built around a `ToolRegistry` (or replicate its semantics exactly, which is undesirable).

---

## B) HiveCore Runtime Truths that Change the Implementation Plan

These items are **hard blockers** or require explicit design decisions.

### B.1 SwiftPM dependency identity conflict (BLOCKER)

If SwiftAgents adds Hive as a dependency, SwiftPM must unify transitive dependencies by identity.

Today:
- SwiftAgents depends on `Conduit` and `Wax` via **URLs** in `/Users/chriskarani/CodingProjects/SwiftAgents/Package.swift`.
- Hive (`/Users/chriskarani/CodingProjects/Hive/libs/hive/Package.swift`) depends on `Conduit` and `Wax` via **local paths**.

This will cause dependency identity conflicts once SwiftAgents depends on Hive.

Decision to lock (pick one):
1) Change Hive (`libs/hive/Package.swift`) to use URL dependencies that match SwiftAgents, OR
2) Change SwiftAgents to use path dependencies for Conduit/Wax that match Hive, OR
3) Introduce a workspace-level strategy (e.g. consistent local overrides), but keep identities consistent.

Without this, “SwiftAgents depends on HiveCore” will not resolve/build reliably.

### B.2 Reducer signature mismatch (BLOCKER for `messages`)

Current SwiftAgents `HiveAgents.MessagesReducer.reduce` is written for the embedded stub runtime:
- It reduces `left: [HiveChatMessage]` with `right: [[HiveChatMessage]]` (batch of writes).

HiveCore reducers are **binary**:
- `reduce(current:update:)` where the runtime applies multiple writes sequentially in deterministic order.

Required change:
- Rewrite the messages reducer as `reduce(current:[HiveChatMessage], update:[HiveChatMessage]) -> [HiveChatMessage]`.
- Preserve the same semantics (including “last removeAll marker wins across the applied sequence of updates”).

### B.3 Interrupts always require checkpoint store (BLOCKER for tool approval)

HiveCore enforces:
- If a step produces an interrupt, the runtime will checkpoint regardless of checkpoint policy.
- If `environment.checkpointStore` is nil when an interrupt occurs, HiveCore throws `HiveRuntimeError.checkpointStoreMissing`.

Implication:
- **Tool approval flows require a checkpoint store** whenever `toolApprovalPolicy` can produce interrupts (e.g. `.always`, `.allowList(...)`).
- Defaulting to `.disabled` checkpoint policy does *not* remove the checkpoint requirement for interrupts.

Required preflight:
- If tool approval can interrupt, require `checkpointStore` at runtime construction.

### B.4 Codecs are required for all task-local channels (and checkpointed global channels)

HiveCore requires codecs when:
- `scope == .taskLocal` (always), OR
- `scope == .global && persistence == .checkpointed`

Implication for `HiveAgents.Schema`:
- `currentToolCall` is task-local → codec required even if the caller “doesn’t use checkpointing”.
- All global checkpointed channels also require codecs.

This must be handled inside SwiftAgents’ `HiveAgents.Schema.channelSpecs` by providing deterministic codecs (typically JSON, sorted keys) for:
- `[HiveChatMessage]`
- `[HiveToolCall]`
- `String?`
- `[HiveChatMessage]?`
- `HiveToolCall?`

### B.5 Error shapes differ from the embedded stub runtime

Examples:
- HiveCore `HiveRuntimeError.invalidRunOptions(String)` vs stub `.invalidRunOptions`.
- HiveCore `HiveRuntimeError.modelStreamInvalid(String)` vs stub `.modelStreamInvalid`.

Implementation and tests must be updated to match HiveCore errors; do not “reintroduce” stub error enums in SwiftAgents.

---

## C) Corrections/Upgrades to the Existing Plan (Implementation-Ready)

These changes make the plan “100% implementable” with HiveCore as the only runtime.

### C.1 Update Phase 1: Add “Dependency Identity Alignment” as the first concrete step

Before adding Hive as a dependency in SwiftAgents, lock and implement the dependency identity strategy for Conduit/Wax (see §B.1).

### C.2 Update Phase 3: Explicitly require HiveGraphBuilder + router usage decision

HiveCore’s `CompiledHiveGraph` does not expose a public initializer; it is produced via `HiveGraphBuilder.compile()`.

Recommended approach for `HiveAgents.makeToolUsingChatAgent(...)`:
- Nodes: `preModel`, `model`, `tools`, `toolExecute`, optional `postModel`.
- Use a router on:
  - `model` (if no `postModel`), else
  - `postModel`
  The router reads `pendingToolCalls` and returns `.end` vs `.nodes([tools])`.

This eliminates the need for a dedicated `routeAfterModel` node, reduces graph surface area, and matches HiveCore routing semantics (routers execute when output.next is `.useGraphEdges`).

### C.3 Update Phase 3: Redesign `HiveAgentsContext` to remove duplicated tool definitions

Current design stores:
- `context.tools: [HiveToolDefinition]` (used for model requests), AND
- `environment.tools: AnyHiveToolRegistry?` (used for invocation)

This is easy to misuse if they diverge.

Required change:
- Remove `tools: [HiveToolDefinition]` from `HiveAgentsContext`.
- Use `input.environment.tools?.listTools()` for model requests (sorted deterministically).
- Keep the tool registry (execution) as the single source of truth.

### C.4 Update Phase 4: Provide a façade that does not depend on HiveRuntime internals

HiveCore’s `HiveRuntime` keeps `environment` private; the façade must not rely on `await runtime.environment`.

Recommended façade surface:
- Construct `HiveRuntime` internally from `(graph, environment)` and keep `environment` stored in the façade (for preflight only).
- Either:
  - Make façade methods `throws` for preflight failures, OR
  - Provide a compatibility `HiveRunHandle.failed(...)` helper as an extension (constructed with a failing `events` stream + failing `outcome` task).

### C.5 Update Phase 5 (Tests): Use HiveRuntime-driven tests + `applyExternalWrites`

Because HiveCore’s `HiveStoreView` is not publicly constructible, tests cannot “call nodes directly with a fake store.”

Recommended testing strategy:
1) Pure unit tests:
   - Messages reducer tests can remain pure (call reducer directly).
2) Runtime-driven node/graph tests:
   - Use `HiveRuntime.applyExternalWrites(threadID:writes:options:)` to seed `messages`, `pendingToolCalls`, etc, without triggering `Schema.inputWrites`.
   - Run with `HiveRunOptions(maxSteps: 1)` to isolate a single step where needed.
   - Read final state via `HiveRunOutcome.output` using `.channels([...])` output projection.
3) Deterministic ID tests:
   - Derive `runID` from `HiveRunHandle.runID`
   - Derive relevant `taskID` values from `HiveEventKind.taskStarted(...)` events
   - Compute expected message IDs based on those values (do not inject fake `taskID` strings).

### C.6 Tool adapter: implement the “correct” bridge

Required change:
- `SwiftAgentsToolRegistry` should use a SwiftAgents `ToolRegistry` under the hood (or accept one), and route `HiveToolCall` → `ToolRegistry.execute`.
- Schema generation should include:
  - `required`
  - `description`
  - `default` (when `ToolParameter.defaultValue` exists)
  - `additionalProperties: false` (optional but recommended for model control)

---

## D) Decisions to Lock Before Implementation Starts

1) Dependency identity strategy for Conduit/Wax (see §B.1).
2) `HiveAgentsRuntime` API shape:
   - `throws` vs “failed handle” compatibility helpers.
3) Do we add public defaults in HiveCore for `HiveClock` / `HiveLogger`?
   - Strongly recommended: `HiveSystemClock` + `HiveNoopLogger` in HiveCore (not SwiftAgents), to avoid SwiftAgents becoming a “runtime utilities” owner.
4) Do we add `Equatable` conformances in HiveCore for chat/tool value types?
   - Optional but reduces test friction and improves ergonomics; otherwise update tests to compare fields.

---

## E) Net Result: What “Hive is the Only Runtime” Means Concretely

After applying this addendum:
- SwiftAgents deletes `Sources/HiveSwiftAgents/HiveCore.swift` and stops defining any runtime primitives.
- `HiveSwiftAgents` imports and re-exports `HiveCore` types, and builds the prebuilt agent graph using:
  - `HiveGraphBuilder`
  - `HiveRuntime`
  - `HiveEnvironment`
- Tool execution bridges into SwiftAgents tools via `ToolRegistry`, not ad-hoc execution.
- Checkpointing is configured when and only when required (interrupts require checkpoint store).

