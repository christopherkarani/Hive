---
sidebar_position: 1
title: Schema System
description: HiveSchema protocol, typed channels, reducers, codecs, and type erasure.
---

# Schema System

A schema declares the typed state channels for a workflow. Every Hive graph is parameterized by a `Schema: HiveSchema`.

## The HiveSchema Protocol

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

| Associated Type | Purpose |
|----------------|---------|
| `Context` | User-defined context passed to every node via `HiveEnvironment` |
| `Input` | Typed input for `runtime.run()` — converted to writes before step 0 |
| `InterruptPayload` | Data type attached to interrupt requests |
| `ResumePayload` | Data type provided when resuming from an interrupt |

## Channel Specs

Each channel is declared via `HiveChannelSpec<Schema, Value>`:

```swift
public struct HiveChannelSpec<Schema: HiveSchema, Value: Sendable>: Sendable {
    public let key: HiveChannelKey<Schema, Value>
    public let scope: HiveChannelScope          // .global or .taskLocal
    public let reducer: HiveReducer<Value>      // merge strategy
    public let updatePolicy: HiveUpdatePolicy   // .single or .multi
    public let initial: @Sendable () -> Value   // default value factory
    public let codec: HiveAnyCodec<Value>?      // serialization for checkpoints
    public let persistence: HiveChannelPersistence
}
```

## Channel Keys

Type-safe references to channels:

```swift
let messages = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
let score = HiveChannelKey<MySchema, Int>(HiveChannelID("score"))
```

## Scopes

| Scope | Store | Visibility |
|-------|-------|-----------|
| `.global` | `HiveGlobalStore` | Shared across all tasks in a thread |
| `.taskLocal` | `HiveTaskLocalStore` | Isolated per spawned task (fan-out) |

## Persistence Modes

| Level | Checkpointed? | Reset behavior |
|-------|--------------|----------------|
| `.checkpointed` | Yes | Survives across interrupt/resume |
| `.untracked` | No | Preserved across supersteps, not saved |
| `.ephemeral` | No | Reset to `initial()` after each superstep |

## Reducers

When multiple nodes write to the same channel in one superstep, the reducer defines how writes merge:

```swift
public struct HiveReducer<Value: Sendable>: Sendable {
    public init(_ reduce: @escaping @Sendable (Value, Value) throws -> Value)
    public func reduce(current: Value, update: Value) throws -> Value
}
```

### Built-in Reducers

| Reducer | Constraint | Behavior |
|---------|-----------|----------|
| `.lastWriteWins()` | Any | Replaces current with update |
| `.append()` | `RangeReplaceableCollection` | Appends update to current |
| `.appendNonNil()` | Optional collection | Nil-safe append |
| `.setUnion()` | `Set<Hashable>` | Union of current and update |
| `.dictionaryMerge(valueReducer:)` | `[String: V]` | Merges dictionaries, resolving conflicts via inner reducer |
| `.sum()` | `Numeric` | Adds current + update |
| `.min()` | `Comparable` | Keeps the lesser value |
| `.max()` | `Comparable` | Keeps the greater value |
| `.binaryOp(_:)` | Any | Custom binary operator |
| `HiveReducer { current, update in ... }` | Any | Fully custom reducer |

## Codecs

Channels that are checkpointed or task-local require a codec for serialization:

```swift
public protocol HiveCodec: Sendable {
    associatedtype Value: Sendable
    var id: String { get }
    func encode(_ value: Value) throws -> Data
    func decode(_ data: Data) throws -> Value
}
```

**Built-in:** `HiveJSONCodec<Value: Codable>` provides JSON serialization. Custom codecs (e.g., `StringCodec`, `StringArrayCodec`) implement the protocol directly.

**Type erasure:** `HiveAnyCodec<Value>` wraps any concrete codec.

## Type Erasure Pattern

`AnyHiveChannelSpec<Schema>` erases the `Value` generic from `HiveChannelSpec<Schema, Value>`, allowing heterogeneous channel specs in the `channelSpecs` array. It uses boxed closures (`_reduceBox`, `_initialBox`, `_encodeBox`, `_decodeBox`) to maintain type safety at runtime.

## Complete Schema Example

```swift
enum MySchema: HiveSchema {
    typealias Input = String
    typealias InterruptPayload = String
    typealias ResumePayload = String

    enum Channels {
        static let messages = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
        static let item = HiveChannelKey<MySchema, String>(HiveChannelID("item"))
    }

    static var channelSpecs: [AnyHiveChannelSpec<MySchema>] {
        [
            AnyHiveChannelSpec(HiveChannelSpec(
                key: Channels.messages,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                codec: HiveAnyCodec(HiveJSONCodec<[String]>()),
                persistence: .checkpointed
            )),
            AnyHiveChannelSpec(HiveChannelSpec(
                key: Channels.item,
                scope: .taskLocal,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                codec: HiveAnyCodec(HiveJSONCodec<String>()),
                persistence: .checkpointed
            )),
        ]
    }

    static func inputWrites(
        _ input: String,
        inputContext: HiveInputContext
    ) throws -> [AnyHiveWrite<MySchema>] {
        [AnyHiveWrite(Channels.messages, [input])]
    }
}
```

## @HiveSchema Macro

The `@HiveSchema` macro eliminates boilerplate:

```swift
@HiveSchema
enum MySchema: HiveSchema {
    @Channel(reducer: "lastWriteWins()", persistence: "untracked")
    static var _answer: String = ""

    @TaskLocalChannel(reducer: "append()", persistence: "checkpointed")
    static var _logs: [String] = []
}
```

The macro generates typed `HiveChannelKey` properties, `channelSpecs`, codecs, and scope configuration.
