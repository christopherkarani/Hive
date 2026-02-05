import Foundation
import Wax

public struct WaxRecall<Schema: HiveSchema>: WorkflowComponent, Sendable {
    private let id: HiveNodeID
    private let memory: SendableKeyPath<Schema.Context, MemoryOrchestrator>
    private let queryProvider: @Sendable (HiveStoreView<Schema>) throws -> String
    private let writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>

    public init(
        _ id: String,
        memory: KeyPath<Schema.Context, MemoryOrchestrator>,
        query: String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.init(
            id: HiveNodeID(id),
            memory: SendableKeyPath(memory),
            queryProvider: { _ in query },
            writeSnippetsTo: writeSnippetsTo
        )
    }

    public init(
        _ id: String,
        memory: KeyPath<Schema.Context, MemoryOrchestrator>,
        query: @escaping @Sendable (HiveStoreView<Schema>) throws -> String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.init(
            id: HiveNodeID(id),
            memory: SendableKeyPath(memory),
            queryProvider: query,
            writeSnippetsTo: writeSnippetsTo
        )
    }

    private init(
        id: HiveNodeID,
        memory: SendableKeyPath<Schema.Context, MemoryOrchestrator>,
        queryProvider: @escaping @Sendable (HiveStoreView<Schema>) throws -> String,
        writeSnippetsTo: HiveChannelKey<Schema, [HiveRAGSnippet]>
    ) {
        self.id = id
        self.memory = memory
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
        let memoryKeyPath = memory
        let queryProvider = queryProvider
        let writeSnippetsTo = writeSnippetsTo

        builder.addNode(id) { input in
            let query = try queryProvider(input.store)
            let memory = input.context[keyPath: memoryKeyPath.keyPath]

            let ctx = try await memory.recall(query: query)
            let snippets = ctx.items.map(HiveRAGSnippet.init)

            return HiveNodeOutput(writes: [AnyHiveWrite(writeSnippetsTo, snippets)])
        }
    }
}

private struct SendableKeyPath<Root, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Root, Value>

    init(_ keyPath: KeyPath<Root, Value>) {
        self.keyPath = keyPath
    }
}
