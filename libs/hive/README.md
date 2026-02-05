# Hive (Swift Package)

Hive is a deterministic Swift graph runtime with a SwiftUI‑style DSL and optional adapters for inference, tools, and checkpointing.

## Mental Model (60s)
- Channels are typed storage slots declared in a `HiveSchema` (global or task-local).
- Reducers merge multiple writes to the same channel during a superstep.
- Supersteps execute the current frontier of tasks, then commit writes and build the next frontier.
- Send and join: tasks send writes and next-node decisions; join edges wait for all parents before scheduling a target.
- Checkpoint/resume captures global state + frontier + join barriers so a thread can resume later.

## Modules
- `Hive` — umbrella module for HiveCore + HiveDSL + adapters (one import).
- `HiveCore` — schema, graph builder, runtime, and core types.
- `HiveDSL` — SwiftUI‑style workflow DSL (nodes, edges, branches, effects, patch/diff).
- `HiveConduit` — Conduit-backed `HiveModelClient` adapter.
- `HiveCheckpointWax` — Wax-backed checkpoint store.
- `HiveRAGWax` — Wax RAG primitives (e.g., `WaxRecall`).
- `HiveMacros` — optional macros to generate channel keys/specs and workflow blueprints.
- SwiftAgents integration (separate package): `HiveSwiftAgents` tool registry adapter.

## Start Here
- `Sources/HiveCore/README.md` for the mental model and core API.
- `Sources/HiveConduit/README.md` for Conduit model wiring.
- `Sources/HiveCheckpointWax/README.md` for checkpoint storage.
- `Sources/HiveSwiftAgents/README.md` for SwiftAgents integration (requires SwiftAgents package).
- `Sources/HiveDSL/` for the declarative workflow DSL.

## Examples
- `Examples/README.md` for runnable SwiftPM examples.

## Usage
- Full stack: `import Hive`
- DSL-only: `import HiveDSL`
- RAG primitives: `import HiveRAGWax`
- Macros: `import HiveMacros`
- Minimal core: `import HiveCore`

## DSL Quickstart (Workflow + Effects)
```swift
import HiveDSL
import HiveCore

enum SupportSchema: HiveSchema {
    enum Channels {
        static let input = HiveChannelKey<SupportSchema, String>(HiveChannelID("input"))
        static let notes = HiveChannelKey<SupportSchema, [String]>(HiveChannelID("notes"))
        static let answer = HiveChannelKey<SupportSchema, String>(HiveChannelID("answer"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<SupportSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.input,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
        ),
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.notes,
                scope: .global,
                reducer: .append(),
                updatePolicy: .multi,
                initial: { [] },
                persistence: .untracked
            )
        ),
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.answer,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
        )
    ]
}

let workflow = Workflow<SupportSchema> {
    Node("Start") { input in
        let text = try input.store.get(SupportSchema.Channels.input)
        return Effects {
            Append(SupportSchema.Channels.notes, elements: ["in:\(text)"])
            GoTo("LLM")
        }
    }
    .start()

    ModelTurn("LLM", model: "gpt-4o-mini") { store in
        let text = try store.get(SupportSchema.Channels.input)
        return [HiveChatMessage(id: "u1", role: .user, content: text)]
    }
    .tools(.environment)
    .writes(to: SupportSchema.Channels.answer)

    Branch(from: "LLM") {
        Branch.case(name: "needsReview", when: { store in
            (try? store.get(SupportSchema.Channels.answer).contains("refund")) ?? false
        }) {
            GoTo("HumanReview")
        }
        Branch.default { UseGraphEdges() }
    }

    Node("HumanReview") { _ in Effects { End() } }
    Node("Done") { _ in Effects { End() } }
    Edge("LLM", to: "Done")
}
```

## Inference (Conduit)
```swift
import Hive
import Conduit

let provider = MyConduitProvider() // conforms to Conduit.TextGenerator
let modelClient = AnyHiveModelClient(
    ConduitModelClient(
        provider: provider,
        modelIDForName: { _ in /* map Hive model names to provider model IDs */ }
    )
)

let environment = HiveEnvironment<SupportSchema>(
    context: (),
    clock: appClock,
    logger: appLogger,
    model: modelClient,
    tools: toolRegistry
)
```

## RAG (Wax)
```swift
import HiveRAGWax
import Wax

struct RAGContext: Sendable { let memory: MemoryOrchestrator }

enum RAGSchema: HiveSchema {
    static let snippets = HiveChannelKey<RAGSchema, [HiveRAGSnippet]>(HiveChannelID("snippets"))
    static let channelSpecs: [AnyHiveChannelSpec<RAGSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: snippets,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { [] },
                persistence: .untracked
            )
        )
    ]
}

let workflow = Workflow<RAGSchema> {
    WaxRecall("Recall", memory: \.memory, query: "alpha", writeSnippetsTo: RAGSchema.snippets)
        .start()
}
```

## Patch & Diff
```swift
var patch = WorkflowPatch<SupportSchema>()
patch.insertProbe("Probe", between: "LLM", and: "Done") { _ in
    Effects { End() }
}

let result = try patch.apply(to: workflow.compile())
let mermaid = result.diff.renderMermaid()
```
Note: `insertProbe` only rewrites static edges (not routers or joins).

## Macros (Optional)
```swift
import HiveMacros

@HiveSchema
enum MacroSchema: HiveSchema {
    @Channel(reducer: "append()", persistence: "untracked")
    static var _messages: [String] = []

    @TaskLocalChannel(reducer: "lastWriteWins()", persistence: "checkpointed")
    static var _localState: String = ""
}
```
Notes:
- Use the `_name` convention to generate `static let name` channel keys.
- Checkpointed/task‑local channels use `HiveJSONCodec` by default; pass `codec: "MyCodec()"` for custom codecs.

## Runtime Basics
```swift
let graph = try workflow.compile()
let runtime = HiveRuntime(graph: graph, environment: environment)
let handle = await runtime.run(
    threadID: HiveThreadID("thread-1"),
    input: (),
    options: HiveRunOptions(maxSteps: 50)
)
let outcome = try await handle.outcome.value
```

## Development
- Build: `make build`
- Test: `make test`
- Format: `make format` (skips if `swiftformat` is not installed)
- Lint: `make lint` (skips if `swiftlint` is not installed)
- Release checklist: `../../docs/hive-release-checklist.md`
