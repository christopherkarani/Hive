# Getting Started with Hive

Add Hive, define a schema, build a graph, and run it.

```swift
import Hive

enum GreetingSchema: HiveSchema {
    typealias Input = String

    static let message = HiveChannelKey<Self, String>(HiveChannelID("message"))

    static var channelSpecs: [AnyHiveChannelSpec<Self>] {
        [
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: message,
                    scope: .global,
                    reducer: .lastWriteWins(),
                    initial: { "" },
                    persistence: .untracked
                )
            )
        ]
    }

    static func inputWrites(_ input: String, inputContext: HiveInputContext) throws -> [AnyHiveWrite<Self>] {
        [AnyHiveWrite(message, input)]
    }
}

var builder = HiveGraphBuilder<GreetingSchema>(start: [HiveNodeID("greet")])
builder.addNode(HiveNodeID("greet")) { input in
    let name = try input.store.get(GreetingSchema.message)
    return HiveNodeOutput(
        writes: [AnyHiveWrite(GreetingSchema.message, "Hello, \(name)!")],
        next: .end
    )
}

let graph = try builder.compile()
```

Create a `HiveEnvironment` with your `HiveClock` and `HiveLogger` implementations, then run the graph through `HiveRuntime`.
