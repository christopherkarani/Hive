# Hive

Deterministic graph runtime for Swift.

Hive executes typed graphs with Bulk Synchronous Parallel semantics: each superstep runs the current frontier, gathers writes, commits atomically, then schedules the next frontier. Nodes never observe another node's same-step writes, which makes runtime behavior reproducible and checkpoint-friendly.

## What Hive Provides

- Typed schemas, channels, reducers, and update policies
- Deterministic graph compilation with validated nodes, edges, routers, and joins
- Superstep runtime with stable task ordering and atomic commits
- Interrupt/resume and checkpoint protocol support
- Runtime event streams for runs, steps, tasks, writes, checkpoints, snapshots, updates, and custom debug events
- Swift 6.2 concurrency-first APIs

Hive is intentionally a graph runtime. DSL, model/tool calling, RAG memory, and provider adapters are not part of this package.

## Quick Start

```swift
import Hive

enum CounterSchema: HiveSchema {
    static let value = HiveChannelKey<Self, Int>(HiveChannelID("value"))

    static var channelSpecs: [AnyHiveChannelSpec<Self>] {
        [
            AnyHiveChannelSpec(
                HiveChannelSpec(
                    key: value,
                    scope: .global,
                    reducer: .sum,
                    updatePolicy: .multi,
                    initial: { 0 },
                    persistence: .untracked
                )
            )
        ]
    }
}

var builder = HiveGraphBuilder<CounterSchema>(start: [HiveNodeID("increment")])
builder.addNode(HiveNodeID("increment")) { _ in
    HiveNodeOutput(
        writes: [AnyHiveWrite(CounterSchema.value, 1)],
        next: .end
    )
}

let graph = try builder.compile()
let runtime = try HiveRuntime(
    graph: graph,
    environment: HiveEnvironment(
        context: (),
        clock: AppClock(),
        logger: AppLogger()
    )
)
```

`AppClock` and `AppLogger` are your implementations of `HiveClock` and `HiveLogger`.

## Products

| Product | Description |
| --- | --- |
| `Hive` | Umbrella library that re-exports `HiveCore` |
| `HiveCore` | Core deterministic graph runtime |
| `HiveTinyGraphExample` | Runnable fan-out, join, interrupt/resume example |

## Requirements

| Platform | Min Version |
| --- | --- |
| Swift | 6.2 |
| iOS | 26.0+ |
| macOS | 26.0+ |
| Linux | Swift 6.2 toolchain |

## Run

```sh
swift build
swift run HiveTinyGraphExample
swift test --filter HiveCoreTests
```

## Documentation

Full documentation is available at [christopherkarani.github.io/Hive](https://christopherkarani.github.io/Hive/).

## License

MIT
