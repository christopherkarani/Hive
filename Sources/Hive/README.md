# Hive

Deterministic graph runtime for Swift.

Hive contains the core Bulk Synchronous Parallel runtime, graph builder, schema/channel system, reducers, checkpoint protocols, interrupt/resume support, and runtime event streams.

Use `HiveGraphBuilder` to define graphs explicitly:

```swift
var builder = HiveGraphBuilder<MySchema>(start: [HiveNodeID("start")])
builder.addNode(HiveNodeID("start")) { input in
    HiveNodeOutput(next: .end)
}
let graph = try builder.compile()
```

## Products

| Product | Description |
| --- | --- |
| `Hive` | Re-exports `HiveCore` |
| `HiveCore` | Core graph runtime |
| `HiveTinyGraphExample` | Runnable core runtime example |

Hive does not ship a workflow DSL, model/tool calling, RAG memory, or provider adapters.
