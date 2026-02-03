# HiveCore

HiveCore provides the schema, graph builder, and deterministic runtime for Hive.

## Mental Model
- Channels are typed state slots declared in a `HiveSchema`.
- Reducers define how multiple writes to a channel merge within a superstep.
- Supersteps run the current frontier of tasks, then commit writes and schedule the next frontier.
- Send and join: tasks emit writes and routing decisions; join edges wait until all parents have run since the last join before scheduling the target.
- Checkpoint/resume persists global state, frontier, and join barriers so a thread can resume with an interrupt payload.

## Define a Schema
```swift
import HiveCore

enum DemoSchema: HiveSchema {
    typealias Context = Void
    typealias Input = String

    enum Channels {
        static let messages = HiveChannelKey<DemoSchema, [String]>(HiveChannelID("messages"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<DemoSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.messages,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                persistence: .untracked
            )
        )
    ]

    static func inputWrites(
        _ input: String,
        inputContext: HiveInputContext
    ) throws -> [AnyHiveWrite<DemoSchema>] {
        [AnyHiveWrite(Channels.messages, [input])]
    }
}
```

Notes:
- Task-local channels must be `checkpointed` and require a `HiveCodec`.
- Global channels require a codec when `persistence: .checkpointed`.

## Build a Graph
```swift
var builder = HiveGraphBuilder<DemoSchema>(start: [HiveNodeID("Start")])

builder.addNode(HiveNodeID("Start")) { input in
    let messages = try input.store.get(DemoSchema.Channels.messages)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(DemoSchema.Channels.messages, messages + ["done"])],
        next: .end
    )
}

let graph = try builder.compile()
```

To model joins, add a join edge:
`builder.addJoinEdge(parents: [HiveNodeID("A"), HiveNodeID("B")], target: HiveNodeID("Join"))`

## Run in an App
Provide `HiveClock` and `HiveLogger` implementations from your app/runtime.

```swift
let environment = HiveEnvironment<DemoSchema>(
    context: (),
    clock: appClock,
    logger: appLogger,
    model: nil,
    modelRouter: nil,
    tools: nil,
    checkpointStore: nil
)

let runtime = HiveRuntime(graph: graph, environment: environment)
let handle = await runtime.run(
    threadID: HiveThreadID("thread-1"),
    input: "hello",
    options: HiveRunOptions(maxSteps: 50)
)

Task {
    for try await event in handle.events {
        // Inspect `event.kind` for step/task/write/checkpoint updates.
    }
}

let outcome = try await handle.outcome.value
```

Checkpoint/resume flow:
- Provide a `HiveCheckpointStore` in `HiveEnvironment` and enable a checkpoint policy in `HiveRunOptions`.
- On `.interrupted`, resume with `runtime.resume(threadID:interruptID:payload:options:)` using the provided `HiveInterruptID`.

## Examples
- `../../Examples/README.md`
- `../../Tests/HiveCoreTests/Runtime/HiveRuntimeStepAlgorithmTests.swift`
- `../../Tests/HiveCoreTests/Runtime/HiveRuntimeCheckpointTests.swift`
- `../../Tests/HiveCoreTests/Runtime/HiveRuntimeInterruptResumeExternalWritesTests.swift`
