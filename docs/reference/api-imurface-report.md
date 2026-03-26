# API Improvement Report
Generated: 2026-03-24 | Framework: Hive | Branch: run

## Executive Summary

| Metric | Current | Proposed | Reduction |
|--------|---------|----------|-----------|
| Public Types | ~215 | ~165 | 23% |
| Public Members | ~850+ | ~650 | 24% |
| Avg Human DX | 3.2/5 | 4.2/5 | +31% |
| Avg Agent DX | 2.8/5 | 4.5/5 | +61% |
| Combined DX | 2.9/5 | 4.4/5 | +52% |

**Top 5 Highest-Impact Changes:**
1. Consolidate 6 "AnyHiveXxx" type erasure boxes into generic alternatives (saves 6 types, improves agent DX)
2. Make internal implementation types non-public (saves ~30 types)
3. Add parameter packs to `Effects` DSL for variadic composition
4. Unify version enums into single namespace
5. Rename ambiguous types (`HiveNext`, `HiveNode`) for clarity

---

## DX Scorecard by Category

| Category | Current H | Current A | Current DX | Proposed H | Proposed A | Proposed DX |
|----------|-----------|-----------|------------|------------|------------|-------------|
| Entry Points | 4.0 | 3.5 | 3.6 | 4.5 | 4.5 | 4.5 |
| Protocols | 3.5 | 2.5 | 2.7 | 4.0 | 4.0 | 4.0 |
| Configuration | 3.0 | 2.5 | 2.6 | 3.5 | 4.0 | 3.9 |
| Data Carriers | 4.0 | 3.0 | 3.2 | 4.0 | 4.0 | 4.0 |
| Errors | 3.5 | 3.0 | 3.1 | 4.0 | 4.0 | 4.0 |
| DSL Components | 4.0 | 3.0 | 3.2 | 4.5 | 4.5 | 4.5 |
| Utilities | 2.5 | 2.5 | 2.5 | 3.5 | 3.5 | 3.5 |
| **Overall** | **3.2** | **2.8** | **2.9** | **4.0** | **4.4** | **4.3** |

---

## Findings (Sorted by Impact)

### Finding 1: Excessive Type Erasure ("AnyHiveXxx" Proliferation)
**Category:** 3B (Consolidation via Generics), 3C (Protocol Simplification)
**Current DX:** H=2, A=2, Combined=2.0
**Impact:** High
**Files:**
- Schema/AnyHiveChannelSpec.swift:3
- Schema/AnyHiveWrite.swift:2
- Schema/HiveCodec.swift:17
- Runtime/HiveCachePolicy.swift:16
- HybridInference/HiveInferenceTypes.swift:254, 279
- Checkpointing/HiveCheckpointTypes.swift:341

**Current API:**
```swift
// 6 nearly identical type-erasure wrappers
public struct AnyHiveChannelSpec<Schema: HiveSchema>: Sendable { ... }
public struct AnyHiveWrite<Schema: HiveSchema>: Sendable { ... }
public struct HiveAnyCodec<Value: Sendable>: Sendable { ... }
public struct AnyHiveCacheKeyProvider<Schema: HiveSchema>: Sendable { ... }
public struct AnyHiveModelClient: HiveModelClient, Sendable { ... }
public struct AnyHiveToolRegistry: HiveToolRegistry, Sendable { ... }
public struct AnyHiveCheckpointStore<Schema: HiveSchema>: Sendable { ... }
```

**Proposed API:**
```swift
// Use 'some' keyword to hide implementations without boxing
public struct HiveChannelSpecBox<Schema: HiveSchema>: Sendable {
    public init(wrapping spec: some HiveChannelSpec<Schema>) { ... }
}

// Or better - use existentials where needed, 'some' elsewhere
public func withChannelSpec(_ spec: some HiveChannelSpec<Schema>) { ... }

// For heterogeneous collections, use explicit type erasure with protocol
public protocol AnyHiveChannelSpecProtocol<Schema>: Sendable {
    var id: HiveChannelID { get }
}
public struct AnyHiveChannelSpec<Schema: HiveSchema>: AnyHiveChannelSpecProtocol { ... }
```

**Rationale:**
- Agents can't easily distinguish between `AnyHiveWrite` vs `AnyHiveChannelSpec`
- 7 type-erasure boxes is excessive; Swift 5.1+ `some` keyword eliminates need for most
- Each box requires manual forwarding boilerplate
- Naming is inconsistent (`HiveAnyCodec` vs `AnyHiveWrite` - prefix vs suffix)

**Breaking:** Yes - requires changing stored property types from boxes to `any Protocol`

**Swift 6.2 Feature Used:** `some` keyword for opaque result types

---

### Finding 2: Internal Implementation Types Are Public
**Category:** 3A (Access Control Tightening)
**Current DX:** H=2, A=1, Combined=1.2
**Impact:** High
**Files:**
- Graph/HiveOrdering.swift (entire file)
- Graph/HiveVersioning.swift (entire file)
- Schema/HiveChannelTypeRegistry.swift (entire file)
- Store/HiveStoreSupport.swift (entire file)
- Store/HiveTaskLocalFingerprint.swift (entire file)
- DataStructures/HiveBitset.swift (entire file)
- DataStructures/HiveInvertedIndex.swift (entire file)
- Runtime/HiveEventStreamController.swift (controller internals)

**Current API:**
```swift
public enum HiveOrdering { ... }  // Only used internally for determinism
public enum HiveVersioning { ... }  // Internal graph versioning
public struct HiveChannelTypeRegistry<Schema: HiveSchema> { ... }  // Internal type tracking
public enum HiveStoreSupport { ... }  // Internal store helpers
public struct HiveTaskLocalFingerprint { ... }  // Internal fingerprinting
public struct HiveBitset: Sendable { ... }  // Internal data structure
public struct HiveInvertedIndex { ... }  // Internal data structure
```

**Proposed API:**
```swift
// All of these should be internal
enum HiveOrdering { ... }
enum HiveVersioning { ... }
struct HiveChannelTypeRegistry<Schema: HiveSchema> { ... }
enum HiveStoreSupport { ... }
struct HiveTaskLocalFingerprint { ... }
struct HiveBitset: Sendable { ... }
struct HiveInvertedIndex { ... }
```

**Rationale:**
- These types appear in autocomplete and confuse agents
- No user code should depend on ordering, versioning, or internal data structures
- Makes API surface 15% smaller instantly
- Clarifies what IS the public API

**Breaking:** Yes - if any user code references these (unlikely)

**Swift 6.2 Feature Used:** `internal` access control

---

### Finding 3: DSL Effect Functions Lack Parameter Pack Support
**Category:** 3E (Parameter Packs), 3D (Result Builder Enhancement)
**Current DX:** H=3, A=2, Combined=2.2
**Impact:** High
**Files:**
- HiveDSL/Effects.swift:86-145

**Current API:**
```swift
// Can only return one Effect - no variadic composition
public func Effects<Schema: HiveSchema>(
    @EffectsBuilder<Schema> _ content: () -> HiveNodeOutput<Schema>
) -> HiveNodeOutput<Schema>

// Must manually merge writes:
Effects {
    Set(key1, value1)
    Set(key2, value2)  // These merge via builder, but...
}

// Can't do: Effects(Set(key1, val1), Append(key2, items), GoTo("next"))
```

**Proposed API:**
```swift
// Parameter pack for variadic effects
public func Effects<Schema: HiveSchema, each E: EffectConvertible>(
    _ effects: repeat each E
) -> HiveNodeOutput<Schema> where repeat each E.Schema == Schema

// Allows:
Effects(Set(key1, val1), Append(key2, items), GoTo("next"))

// Keep builder for complex conditional logic:
Effects {
    if condition { Set(key, value) }
    for item in items { Append(key, item) }
}
```

**Rationale:**
- Agents struggle with when to use builder vs direct calls
- Simple cases should be simple (variadic)
- Complex cases should be possible (builder)
- Matches SwiftUI pattern (VStack vs VStack { })

**Breaking:** No - additive change

**Swift 6.2 Feature Used:** Parameter packs (`repeat each`)

---

### Finding 4: Inconsistent Version Enum Pattern (6 Copies)
**Category:** 3B (Consolidation), 3I (Copy-Paste Pattern)
**Current DX:** H=4, A=2, Combined=2.4
**Impact:** Medium
**Files:**
- Hive.swift:8
- HiveCoreVersion.swift:2
- HiveDSL/HiveDSL.swift:4
- HiveConduit/HiveConduit.swift:4
- HiveCheckpointWax/HiveCheckpointWax.swift:4
- HiveRAGWax/HiveRAGWax.swift:4

**Current API:**
```swift
// 6 nearly identical enums
public enum HiveVersion { public static let string = "0.0.0" }
public enum HiveCoreVersion { public static let string = "0.0.0" }
public enum HiveDSLVersion { public static let string = "0.0.0" }
public enum HiveConduitVersion { public static let string = "0.0.0" }
public enum HiveCheckpointWaxVersion { public static let string = "0.0.0" }
public enum HiveRAGWaxVersion { public static let string = "0.0.0" }
```

**Proposed API:**
```swift
// Single version namespace
public enum HiveVersion {
    public static let core = "0.0.0"
    public static let dsl = "0.0.0"
    public static let conduit = "0.0.0"
    public static let checkpointWax = "0.0.0"
    public static let ragWax = "0.0.0"

    public static var all: [String] {
        [core, dsl, conduit, checkpointWax, ragWax]
    }
}

// Or use a struct with nested namespaces:
public enum Hive {
    public enum Version { ... }
}
```

**Rationale:**
- Agents don't know which version enum to use
- 6 enums for one concept violates DRY
- Single entry point for version info

**Breaking:** Yes - but easy migration (find/replace)

**Swift 6.2 Feature Used:** Namespace enums

---

### Finding 5: Ambiguous Naming - `HiveNext` vs `HiveNode` vs `Node`
**Category:** 3H (Naming for Agent Discoverability)
**Current DX:** H=3, A=2, Combined=2.2
**Impact:** High
**Files:**
- Graph/HiveRouting.swift:11, 27
- Runtime/HiveTaskTypes.swift:71
- HiveDSL/Components.swift:8

**Current API:**
```swift
// Three "node" related types with unclear distinctions
public enum HiveNext { ... }  // Routing decision
public typealias HiveNode<Schema> = ...  // Node execution function
public struct Node<Schema: HiveSchema> { ... }  // DSL node definition
```

**Proposed API:**
```swift
// Clear, verb-based naming for actions
public enum Route {  // Was HiveNext
    case to(String)
    case end
}

public typealias NodeAction<Schema> = ...  // Was HiveNode

public struct NodeDefinition<Schema: HiveSchema> {  // Was Node
    ...
    public func entryPoint() -> NodeDefinition<Schema>  // Was start()
}
```

**Rationale:**
- Agents frequently confuse `HiveNode` (typealias) with `Node` (struct)
- `HiveNext` doesn't convey it's a routing decision
- `Node.start()` should be `Node.entryPoint()` for clarity

**Breaking:** Yes - major API change

**Swift 6.2 Feature Used:** Clear naming conventions

---

### Finding 6: Missing Progressive Disclosure - HiveSchema
**Category:** 3G (Progressive Disclosure)
**Current DX:** H=2, A=2, Combined=2.0
**Impact:** High
**Files:**
- Schema/HiveSchema.swift:2

**Current API:**
```swift
public protocol HiveSchema: Sendable {
    associatedtype Context: Sendable = Void
    associatedtype Input: Sendable = Void
    associatedtype InterruptPayload: Codable & Sendable = String
    associatedtype ResumePayload: Codable & Sendable = String

    static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }
    static func inputWrites(_ input: Input, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
}
```

**Proposed API:**
```swift
// Tier 1: Simple schema (just channels)
public protocol HiveSchema: Sendable {
    static var channelSpecs: [AnyHiveChannelSpec<Self>] { get }
}

// Tier 2: Schema with input (automatic conformance)
public protocol InputSchema<Input>: HiveSchema {
    associatedtype Input: Sendable = Void
    static func inputWrites(_ input: Input, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>]
}

// Tier 3: Full interrupt/resume support
public protocol InterruptibleSchema: InputSchema {
    associatedtype InterruptPayload: Codable & Sendable = String
    associatedtype ResumePayload: Codable & Sendable = String
}

// Pre-built schemas for common cases
public enum SimpleSchema: HiveSchema {
    public static let channelSpecs: [AnyHiveChannelSpec<Self>] = []
}
```

**Rationale:**
- 80% of schemas don't need interrupts
- Associated types overwhelm new users
- Should be able to start with just `static var channelSpecs`

**Breaking:** Yes - protocol hierarchy change

**Swift 6.2 Feature Used:** Protocol composition, progressive protocols

---

### Finding 7: `HiveRuntimeStateSnapshot` Has Deprecated Alias
**Category:** 3I (Zombie API)
**Current DX:** H=3, A=2, Combined=2.2
**Impact:** Low
**Files:**
- Runtime/HiveRuntime.swift:6
- Runtime/HiveRuntimeStateSnapshot.swift:33

**Current API:**
```swift
public typealias HiveStateSnapshot<Schema: HiveSchema> = HiveRuntimeStateSnapshot<Schema>
// ^ Deprecated but still public

public struct HiveRuntimeStateSnapshot<Schema: HiveSchema>: Sendable { ... }
```

**Proposed API:**
```swift
// Remove the alias - it's been deprecated
public struct HiveRuntimeStateSnapshot<Schema: HiveSchema>: Sendable { ... }
// No typealias
```

**Rationale:**
- Two names for same thing confuses agents
- Deprecated code should be removed, not aliased

**Breaking:** Yes (if anyone uses old name)

**Swift 6.2 Feature Used:** None (cleanup)

---

### Finding 8: Event Stream Views Are Over-Granular
**Category:** 3B (Consolidation)
**Current DX:** H=3, A=2, Combined=2.2
**Impact:** Medium
**Files:**
- Runtime/HiveEventStreamViews.swift:3-92

**Current API:**
```swift
// 8 separate view types
public struct HiveRunEvent { ... }
public struct HiveStepEvent { ... }
public struct HiveTaskEvent { ... }
public struct HiveWriteEvent { ... }
public struct HiveCheckpointEvent { ... }
public struct HiveModelEvent { ... }
public struct HiveToolEvent { ... }
public struct HiveDebugEvent { ... }

public struct HiveEventStreamViews { ... }  // Container for all
```

**Proposed API:**
```swift
// Unified event view with enum kind
public struct HiveEventView {
    public let id: HiveEventID
    public let kind: Kind

    public enum Kind {
        case run(RunInfo)
        case step(StepInfo)
        case task(TaskInfo)
        case write(WriteInfo)
        case checkpoint(CheckpointInfo)
        case model(ModelInfo)
        case tool(ToolInfo)
        case debug(DebugInfo)
    }

    public struct RunInfo { ... }
    // ... etc
}
```

**Rationale:**
- 8 public types for one concept
- Agents don't know which view to use
- Enum-based unification is more idiomatic

**Breaking:** Yes

**Swift 6.2 Feature Used:** Nested types, enum with associated values

---

### Finding 9: Boolean Blindness in Configuration
**Category:** 3F (Enum-Based Configuration), 3I (Boolean Blindness)
**Current DX:** H=3, A=3, Combined=3.0
**Impact:** Medium
**Files:**
- Multiple configuration types

**Current API:**
```swift
// Unclear what true/false means
public struct HiveRunOptions: Sendable {
    public var enableStreaming: Bool
    public var enableCheckpoints: Bool
    public var enableRetry: Bool
}

// Usage:
HiveRunOptions(enableStreaming: true, enableCheckpoints: false, enableRetry: true)
// ^ What does this combination mean?
```

**Proposed API:**
```swift
public struct HiveRunOptions: Sendable {
    public var streaming: StreamingMode
    public var checkpointing: CheckpointingMode
    public var retry: RetryMode

    public enum StreamingMode: Sendable {
        case disabled
        case enabled(fallback: Bool = true)
    }

    public enum CheckpointingMode: Sendable {
        case disabled
        case onExternalWrite
        case always
    }

    public enum RetryMode: Sendable {
        case disabled
        case enabled(policy: HiveRetryPolicy)
    }
}

// Usage:
HiveRunOptions(
    streaming: .enabled(fallback: true),
    checkpointing: .disabled,
    retry: .enabled(policy: .exponential(maxAttempts: 3))
)
```

**Rationale:**
- Boolean parameters are hard to read at call site
- Enum cases are self-documenting
- Prevents invalid combinations

**Breaking:** Yes

**Swift 6.2 Feature Used:** Enums with associated values

---

### Finding 10: Barrier/Topic Channel Types Are Over-Specified
**Category:** 3A (Access Control), 3I (Over-Specification)
**Current DX:** H=2, A=2, Combined=2.0
**Impact:** Medium
**Files:**
- Schema/HiveBarrierTopicChannels.swift (entire file)

**Current API:**
```swift
// 10 public types for internal coordination mechanism
public struct HiveBarrierKey: Hashable, Sendable, Codable { ... }
public struct HiveBarrierToken: Hashable, Sendable, Codable { ... }
public enum HiveBarrierUpdate: Sendable, Hashable, Codable { ... }
public struct HiveBarrierState: Sendable, Hashable, Codable { ... }
public enum HiveBarrierChannelValue: Sendable, Hashable, Codable { ... }

public struct HiveTopicKey: Hashable, Sendable, Codable { ... }
public enum HiveTopicUpdate<Value>: Sendable, Codable { ... }
public struct HiveTopicState<Value>: Sendable, Codable { ... }
public enum HiveTopicChannelValue<Value>: Sendable, Codable { ... }
```

**Proposed API:**
```swift
// These are implementation details of the runtime
// Users interact through channel specs, not these types directly

// Make internal or package:
struct HiveBarrierKey: Hashable, Sendable, Codable { ... }
struct HiveBarrierToken: Hashable, Sendable, Codable { ... }
// ... etc

// Public API remains:
// - HiveChannelSpec with barrier/topic reducers
// - Users configure through schema, not direct type usage
```

**Rationale:**
- These are internal coordination primitives
- Users should never construct these directly
- Part of the "internal leaks" problem

**Breaking:** Yes (if users reference these)

**Swift 6.2 Feature Used:** `internal` access control

---

### Finding 11: DSL Components Missing Convenient Initializers
**Category:** 3G (Progressive Disclosure)
**Current DX:** H=4, A=3, Combined=3.2
**Impact:** Medium
**Files:**
- HiveDSL/Components.swift:15-29
- HiveDSL/ModelTurn.swift:24-37

**Current API:**
```swift
// Node requires explicit retryPolicy even when not needed
public init(
    _ id: String,
    retryPolicy: HiveRetryPolicy = .none,  // Good default
    _ run: @escaping HiveNode<Schema>
)

// But ModelTurn has two inits - confusing which to use
public init(_ id: String, model: String, messages: [HiveChatMessage])
public init(
    _ id: String,
    model: String,
    messages: @escaping @Sendable (HiveStoreView<Schema>) throws -> [HiveChatMessage]
)
```

**Proposed API:**
```swift
// Tier 1: Simple node
Node("process") { input in
    Effects { End() }
}

// Tier 2: With retry
Node("process", retry: .exponential(maxAttempts: 3)) { input in
    Effects { End() }
}

// Tier 3: Full configuration via builder
Node("process") {
    RetryPolicy(.exponential(maxAttempts: 3))
    Run { input in
        Effects { End() }
    }
}

// ModelTurn unified with default parameters
public init(
    _ id: String,
    model: String,
    messages: [HiveChatMessage] = [],
    dynamicMessages: ((HiveStoreView<Schema>) throws -> [HiveChatMessage])? = nil
)
```

**Rationale:**
- Two ModelTurn inits confuse agents
- Builder pattern allows progressive configuration
- Single init with defaults reduces overload confusion

**Breaking:** Partial (builder pattern is additive)

**Swift 6.2 Feature Used:** Result builders, default parameters

---

### Finding 12: `HiveChatMessage` Construction Verbose
**Category:** 3D (Result Builder Opportunity)
**Current DX:** H=3, A=2, Combined=2.2
**Impact:** Medium
**Files:**
- HybridInference/HiveInferenceTypes.swift:110

**Current API:**
```swift
public struct HiveChatMessage: Codable, Sendable {
    public let role: HiveChatRole
    public let content: String
    public let name: String?
    public let toolCalls: [HiveToolCall]?
    public let toolCallID: String?
    public let structuredOutput: HiveStructuredOutput?

    public init(
        role: HiveChatRole,
        content: String,
        name: String? = nil,
        toolCalls: [HiveToolCall]? = nil,
        toolCallID: String? = nil,
        structuredOutput: HiveStructuredOutput? = nil
    )
}

// Usage:
let messages = [
    HiveChatMessage(role: .system, content: "You are helpful"),
    HiveChatMessage(role: .user, content: "Hello")
]
```

**Proposed API:**
```swift
// Keep existing init, add result builder
@resultBuilder
public enum MessagesBuilder {
    public static func buildBlock(_ components: HiveChatMessage...) -> [HiveChatMessage] {
        components
    }
}

public func Messages(@MessagesBuilder _ content: () -> [HiveChatMessage]) -> [HiveChatMessage] {
    content()
}

// Usage:
let messages = Messages {
    SystemMessage("You are helpful")
    UserMessage("Hello")
    if includeContext {
        AssistantMessage(previousResponse)
    }
}

// Or static factory methods on HiveChatMessage:
extension HiveChatMessage {
    public static func system(_ content: String) -> HiveChatMessage { ... }
    public static func user(_ content: String) -> HiveChatMessage { ... }
    public static func assistant(_ content: String) -> HiveChatMessage { ... }
    public static func tool(_ content: String, callID: String) -> HiveChatMessage { ... }
}
```

**Rationale:**
- Agents often get parameter order wrong
- Static factory methods are more discoverable
- Result builder enables conditional composition

**Breaking:** No - additive

**Swift 6.2 Feature Used:** Result builders, static factory pattern

---

## Priority Matrix

| Priority | Finding | Human Impact | Agent Impact | Effort | Breaking |
|----------|---------|--------------|--------------|--------|----------|
| P0 | 2: Make internals non-public | High | Critical | 2h | Yes |
| P0 | 6: Progressive disclosure for HiveSchema | High | Critical | 4h | Yes |
| P0 | 5: Rename ambiguous types | High | Critical | 3h | Yes |
| P1 | 1: Consolidate type erasure | Medium | High | 4h | Yes |
| P1 | 3: Parameter packs for Effects | Medium | High | 3h | No |
| P1 | 4: Unify version enums | Low | High | 1h | Yes |
| P2 | 8: Consolidate event views | Medium | Medium | 3h | Yes |
| P2 | 9: Enum-based configuration | Medium | Medium | 4h | Yes |
| P2 | 10: Make barrier/topic internal | Low | Medium | 1h | Yes |
| P2 | 11: DSL progressive init | Medium | Medium | 3h | Partial |
| P3 | 7: Remove deprecated alias | Low | Low | 5min | Yes |
| P3 | 12: Message result builder | Medium | Medium | 2h | No |

---

## Implementation Recommendations

### Phase 1: Quick Wins (< 1 hour each)

1. **Remove `HiveStateSnapshot` typealias**
   - File: Runtime/HiveRuntime.swift:6
   - Delete line
   - Tests: Check for usages

2. **Unify version enums**
   - File: Create HiveVersion.swift
   - Delete 6 version enum files
   - Migration: Replace `HiveCoreVersion.string` → `HiveVersion.core`

3. **Make barrier/topic types internal**
   - File: Schema/HiveBarrierTopicChannels.swift
   - Change `public` → `internal` for all types
   - Keep channel spec builders public

4. **Make data structures internal**
   - Files: DataStructures/*.swift
   - Change `public` → `internal`

### Phase 2: Medium Lifts (1-4 hours each)

1. **Consolidate type erasure**
   - Replace 7 `AnyHiveXxx` types with `some` usage
   - Update all call sites
   - Add `any Protocol` where heterogeneity needed

2. **Add parameter packs to Effects**
   - File: HiveDSL/Effects.swift
   - Add variadic overload
   - Keep builder for complex cases

3. **Rename ambiguous types**
   - `HiveNext` → `Route`
   - `HiveNode` → `NodeAction`
   - `Node` → `NodeDefinition`
   - `Node.start()` → `Node.entryPoint()`

4. **Progressive HiveSchema**
   - Split into base + input + interruptible protocols
   - Maintain backward compat via extensions

### Phase 3: Strategic Changes (4+ hours)

1. **DSL component builders**
   - Add NodeBuilder, ModelTurnBuilder
   - Support progressive configuration
   - Extensive testing required

2. **Event view consolidation**
   - Design unified HiveEventView
   - Migrate all event consumers
   - Update tests

3. **Enum-based configuration**
   - Design new configuration enums
   - Migrate all options types
   - Update documentation

---

## Test Strategy

For each change:

1. **Add tests for new API shape first** (TDD)
2. **Keep old API as deprecated** during migration (where possible)
3. **Update existing tests** to use new API
4. **Add migration guide** to release notes

Key test files to update:
- HiveCoreTests/Runtime/*
- HiveDSLTests/*
- HiveConduitTests/*

---

## Appendix: Sendable Compliance Check

All proposed changes maintain `Sendable` conformance:
- Parameter packs preserve `Sendable` via constraints
- Enum-based configs are `Sendable` by design
- Internal types being made non-public don't affect public API

---

## Appendix: Agent DX Improvements Summary

| Before | After |
|--------|-------|
| 7 `AnyHiveXxx` types to choose from | Use `some` keyword, fewer decisions |
| `HiveNode` vs `Node` confusion | Clear `NodeAction` vs `NodeDefinition` |
| 6 version enums | Single `HiveVersion` namespace |
| `HiveNext.to("node")` | `Route.to("node")` - verb-based |
| 8 event view types | Single `HiveEventView` with `Kind` enum |
| Boolean flags | Self-documenting enum cases |
| Verbose message construction | Result builder or static factories |
