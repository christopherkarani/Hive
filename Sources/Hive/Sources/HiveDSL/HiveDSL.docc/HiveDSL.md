# ``HiveDSL``

Result-builder DSL for declaratively defining Hive workflow graphs.

@Metadata {
    @DisplayName("HiveDSL")
}

## Overview

HiveDSL provides a Swift result-builder API for constructing workflow graphs. Instead of using the imperative `HiveGraphBuilder`, you declare nodes, edges, branches, and effects using a SwiftUI-inspired syntax that compiles to the same `CompiledHiveGraph`.

```swift
let workflow = Workflow<MySchema> {
    Node("classify") { input in
        let text = try input.store.get(MySchema.text)
        Effects {
            Set(MySchema.category, classify(text))
            UseGraphEdges()
        }
    }.start()

    Node("respond") { _ in Effects { End() } }
    Node("escalate") { _ in Effects { End() } }

    Branch(from: "classify") {
        Branch.case(name: "urgent", when: {
            (try? $0.get(MySchema.category)) == "urgent"
        }) {
            GoTo("escalate")
        }
        Branch.default { GoTo("respond") }
    }
}

let graph = try workflow.compile()
```

## Topics

### Essentials

- <doc:BuildingWorkflows>
- <doc:UsingEffects>

### Nodes

- ``Workflow``
- ``Node``
- ``ModelTurn``

### Routing

- ``Edge``
- ``Join``
- ``Chain``
- ``Branch``
- ``FanOut``
- ``SequenceEdges``

### Effects

- <doc:UsingEffects>
- ``Effect``

### LLM Integration

- <doc:ModelTurnIntegration>
- ``ModelTurn``

### Advanced

- <doc:AdvancedPatterns>
- ``Subgraph``
- ``WorkflowPatch``
- ``WorkflowBlueprint``
