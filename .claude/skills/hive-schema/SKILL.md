---
name: hive-schema
description: "Generate a HiveSchema enum with typed channels, reducers, and codecs. Supports both manual and @HiveSchema macro approaches."
user-invocable: true
argument-hint: "[channel-names...]"
---

# Hive Schema Generator

Generate a complete `HiveSchema` conforming enum with typed channels.

## Step 1: Gather Channel Information

For each channel, determine:
- **Name** (string ID, used as `HiveChannelID`)
- **Value type** (e.g., `String`, `[String]`, `Int`, custom `Sendable` type)
- **Scope**: `.global` (shared across all tasks) or `.taskLocal` (per-task overlay)
- **Reducer**: How multiple writes merge
  - `.lastWriteWins` — latest value replaces previous
  - `.append()` — concatenate arrays
  - `.setUnion()` — merge sets
  - Custom: `HiveReducer { current, update in ... }`
- **Persistence**: `.tracked` (included in checkpoints) or `.untracked`
- **Codec** (optional): For checkpoint serialization. Use `HiveCodec.json()` for Codable types

## Step 2: Generate Manual Implementation

```swift
import HiveCore

enum MySchema: HiveSchema {
    // Channel keys (static accessors for type-safe reads/writes)
    static let messagesKey = HiveChannelKey<MySchema, [String]>(HiveChannelID("messages"))
    static let counterKey = HiveChannelKey<MySchema, Int>(HiveChannelID("counter"))

    static var channelSpecs: [AnyHiveChannelSpec<MySchema>] {
        let messages = HiveChannelSpec(
            key: messagesKey,
            scope: .global,
            reducer: .append(),
            updatePolicy: .multi,
            initial: { [] },
            persistence: .tracked,
            codec: HiveCodec.json()
        )
        let counter = HiveChannelSpec(
            key: counterKey,
            scope: .global,
            reducer: HiveReducer { current, update in current + update },
            updatePolicy: .multi,
            initial: { 0 },
            persistence: .tracked,
            codec: HiveCodec.json()
        )
        return [
            AnyHiveChannelSpec(messages),
            AnyHiveChannelSpec(counter),
        ]
    }

    static func mapInputs(_ input: MyInput, into writer: inout HiveInputWriter<MySchema>) {
        writer.write(messagesKey, value: input.initialMessages)
    }
}
```

## Step 3: Generate @HiveSchema Macro Version (if using macros)

```swift
import HiveCore
import HiveMacros

@HiveSchema
enum MySchema: HiveSchema {
    @Channel(scope: .global, reducer: .append(), persistence: .tracked)
    static var messages: [String] = []

    @TaskLocalChannel(reducer: .lastWriteWins, persistence: .untracked)
    static var taskStatus: String = "pending"
}
```

## Key Rules

- Channel IDs use lexicographic ordering for determinism
- All value types must be `Sendable`
- Reducers must be deterministic and associative
- Scope determines store placement: `.global` → `HiveGlobalStore`, `.taskLocal` → `HiveTaskLocalStore`
- Codecs are required for checkpointable channels
- `mapInputs` transforms external input into initial channel writes
- See HIVE_SPEC.md §6 for normative requirements
