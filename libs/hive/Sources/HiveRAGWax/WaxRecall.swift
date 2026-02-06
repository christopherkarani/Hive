import Foundation
import Wax

public struct WaxRecall<Schema: HiveSchema>: WorkflowComponent, Sendable {
    private let id: HiveNodeID
    private let memoryResolver: MemoryResolver<Schema.Context>
    private let queryProvider: @Sendable (HiveStoreView<Schema>) throws -> String
    private let writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>

    public init(
        _ id: String,
        memory: sending KeyPath<Schema.Context, MemoryOrchestrator>,
        query: String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.init(
            id: HiveNodeID(id),
            memoryResolver: MemoryResolver(memory),
            queryProvider: { _ in query },
            writeSnippetsTo: writeSnippetsTo
        )
    }

    public init(
        _ id: String,
        memory: sending KeyPath<Schema.Context, MemoryOrchestrator>,
        query: @escaping @Sendable (HiveStoreView<Schema>) throws -> String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.init(
            id: HiveNodeID(id),
            memoryResolver: MemoryResolver(memory),
            queryProvider: query,
            writeSnippetsTo: writeSnippetsTo
        )
    }

    private init(
        id: HiveNodeID,
        memoryResolver: MemoryResolver<Schema.Context>,
        queryProvider: @escaping @Sendable (HiveStoreView<Schema>) throws -> String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.id = id
        self.memoryResolver = memoryResolver
        self.queryProvider = queryProvider
        self.writeSnippetsTo = writeSnippetsTo
    }

    public func start() -> AnyWorkflowComponent<Schema> {
        AnyWorkflowComponent(
            startNodes: [id],
            apply: { builder, design in
                try self.apply(to: &builder, design: &design)
            }
        )
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        let memoryResolver = memoryResolver
        let queryProvider = queryProvider
        let writeSnippetsTo = writeSnippetsTo

        builder.addNode(id) { input in
            let query = try queryProvider(input.store)
            let memory = await memoryResolver.resolve(from: input.context)

            let ctx = try await memory.recall(query: query)
            let snippets = ctx.items.map(HiveRAGSnippet.init)

            return HiveNodeOutput(writes: [AnyHiveWrite(writeSnippetsTo, snippets)])
        }
    }
}

private actor MemoryResolver<Context: Sendable> {
    private let keyPath: KeyPath<Context, MemoryOrchestrator>

    init(_ keyPath: sending KeyPath<Context, MemoryOrchestrator>) {
        self.keyPath = keyPath
    }

    func resolve(from context: Context) -> MemoryOrchestrator {
        context[keyPath: keyPath]
    }
}
