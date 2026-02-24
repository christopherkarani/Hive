# Getting Started with Hive

Add Hive to your project, define a schema, build a graph, and run your first workflow.

## Overview

This guide walks you through adding Hive as a dependency, defining your first schema with typed channels, building a workflow graph, and executing it with the runtime.

## Add the dependency

Add Hive to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Hive.git", branch: "master")
]
```

Then add the product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Hive", package: "Hive")
    ]
)
```

The `Hive` product is batteries-included — it re-exports `HiveCore`, `HiveDSL`, `HiveConduit`, and `HiveCheckpointWax`. For minimal dependency, use `HiveCore` alone.

## Define a schema

A schema declares the typed state channels for your workflow. Every graph is parameterized by a schema conforming to `HiveSchema`.

```swift
import Hive

enum GreetingSchema: HiveSchema {
    typealias Input = String

    static let message = HiveChannelKey<GreetingSchema, String>(
        HiveChannelID("message")
    )

    static var channelSpecs: [AnyHiveChannelSpec<GreetingSchema>] {
        [
            AnyHiveChannelSpec(HiveChannelSpec(
                key: message,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { "" },
                persistence: .untracked
            ))
        ]
    }

    static func inputWrites(
        _ input: String,
        inputContext: HiveInputContext
    ) throws -> [AnyHiveWrite<GreetingSchema>] {
        [AnyHiveWrite(message, input)]
    }
}
```

## Build a graph

Use the `Workflow` result builder to define nodes and routing:

```swift
let workflow = Workflow<GreetingSchema> {
    Node("greet") { input in
        let name = try input.store.get(GreetingSchema.message)
        return Effects {
            Set(GreetingSchema.message, "Hello, \(name)!")
            End()
        }
    }.start()
}

let graph = try workflow.compile()
```

The `.start()` modifier marks the entry-point node. `Effects` accumulate writes and routing decisions. `End()` terminates the workflow.

## Run the workflow

Create an environment and runtime, then execute:

```swift
let env = HiveEnvironment<GreetingSchema>(
    context: (),
    clock: DefaultHiveClock(),
    logger: DefaultHiveLogger()
)

let runtime = try HiveRuntime(graph: graph, environment: env)

let handle = await runtime.run(
    threadID: HiveThreadID("greeting-1"),
    input: "World",
    options: HiveRunOptions()
)
```

## Read the results

The run handle provides an event stream and a terminal outcome:

```swift
// Collect events
for try await event in handle.events {
    print(event)
}

// Get the final outcome
let outcome = try await handle.outcome.value
switch outcome {
case .finished(let output, _):
    if case .fullStore(let store) = output {
        let result = try store.get(GreetingSchema.message)
        print(result) // "Hello, World!"
    }
case .interrupted(let interruption):
    print("Interrupted: \(interruption)")
case .cancelled:
    print("Cancelled")
case .outOfSteps:
    print("Hit step limit")
}
```

## Next steps

- Read <doc:ConceptualOverview> to understand Hive's BSP execution model and determinism guarantees.
- Explore `HiveCore` for the full schema, store, graph, and runtime API.
- Explore `HiveDSL` for the workflow result builder, routing primitives, and LLM integration.
