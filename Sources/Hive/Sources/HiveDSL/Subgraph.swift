import Foundation

/// Error types specific to subgraph execution.
public enum HiveSubgraphError: Error, Sendable {
    case childInterrupted(interruptID: HiveInterruptID)
    case childFailed(Error)
    case childOutputNotFullStore
}

/// A DSL component that embeds a child graph as a single node in the parent workflow.
///
/// When the parent reaches this node, it:
/// 1. Maps parent store to child input via `inputMapping`
/// 2. Maps parent environment to child environment via `environmentMapping`
/// 3. Creates and runs a child `HiveRuntime<ChildSchema>` to completion
/// 4. Maps child outcome to parent writes via `outputMapping`
///
/// The child graph runs in full isolation: it cannot mutate the parent store directly,
/// and it does not violate the parent's superstep determinism.
public struct Subgraph<ParentSchema: HiveSchema, ChildSchema: HiveSchema>: WorkflowComponent, Sendable {
    public typealias Schema = ParentSchema

    public let id: HiveNodeID
    private let childGraph: CompiledHiveGraph<ChildSchema>
    private let inputMapping: @Sendable (HiveStoreView<ParentSchema>) throws -> ChildSchema.Input
    private let environmentMapping: @Sendable (HiveEnvironment<ParentSchema>) throws -> HiveEnvironment<ChildSchema>
    private let outputMapping: @Sendable (HiveRunOutcome<ChildSchema>, HiveGlobalStore<ChildSchema>) throws -> [AnyHiveWrite<ParentSchema>]
    private let childRunOptions: HiveRunOptions
    private let isStart: Bool

    public init(
        _ id: String,
        childGraph: CompiledHiveGraph<ChildSchema>,
        childRunOptions: HiveRunOptions = HiveRunOptions(),
        inputMapping: @escaping @Sendable (HiveStoreView<ParentSchema>) throws -> ChildSchema.Input,
        environmentMapping: @escaping @Sendable (HiveEnvironment<ParentSchema>) throws -> HiveEnvironment<ChildSchema>,
        outputMapping: @escaping @Sendable (HiveRunOutcome<ChildSchema>, HiveGlobalStore<ChildSchema>) throws -> [AnyHiveWrite<ParentSchema>]
    ) {
        self.id = HiveNodeID(id)
        self.childGraph = childGraph
        self.childRunOptions = childRunOptions
        self.inputMapping = inputMapping
        self.environmentMapping = environmentMapping
        self.outputMapping = outputMapping
        self.isStart = false
    }

    private init(
        id: HiveNodeID,
        childGraph: CompiledHiveGraph<ChildSchema>,
        childRunOptions: HiveRunOptions,
        inputMapping: @escaping @Sendable (HiveStoreView<ParentSchema>) throws -> ChildSchema.Input,
        environmentMapping: @escaping @Sendable (HiveEnvironment<ParentSchema>) throws -> HiveEnvironment<ChildSchema>,
        outputMapping: @escaping @Sendable (HiveRunOutcome<ChildSchema>, HiveGlobalStore<ChildSchema>) throws -> [AnyHiveWrite<ParentSchema>],
        isStart: Bool
    ) {
        self.id = id
        self.childGraph = childGraph
        self.childRunOptions = childRunOptions
        self.inputMapping = inputMapping
        self.environmentMapping = environmentMapping
        self.outputMapping = outputMapping
        self.isStart = isStart
    }

    public func start() -> Subgraph<ParentSchema, ChildSchema> {
        Subgraph(
            id: id,
            childGraph: childGraph,
            childRunOptions: childRunOptions,
            inputMapping: inputMapping,
            environmentMapping: environmentMapping,
            outputMapping: outputMapping,
            isStart: true
        )
    }

    public func apply(to builder: inout HiveGraphBuilder<ParentSchema>, design _: inout WorkflowDesign) throws {
        let childGraph = self.childGraph
        let inputMapping = self.inputMapping
        let environmentMapping = self.environmentMapping
        let outputMapping = self.outputMapping
        let childRunOptions = self.childRunOptions

        builder.addNode(id, retryPolicy: .none) { input in
            // 1. Map parent store -> child input
            let childInput = try inputMapping(input.store)

            // 2. Map parent environment -> child environment
            let childEnv = try environmentMapping(input.environment)

            // 3. Create child runtime and run to completion
            let childRuntime = try HiveRuntime<ChildSchema>(graph: childGraph, environment: childEnv)

            // Use a unique child thread ID derived from parent context to avoid collisions
            let childThreadID = HiveThreadID("subgraph:\(input.run.threadID.rawValue):\(input.run.stepIndex)")
            let handle = await childRuntime.run(
                threadID: childThreadID,
                input: childInput,
                options: childRunOptions
            )

            // Drain child events (discard; parent only sees its own events)
            for try await _ in handle.events {}

            // Wait for child outcome
            let outcome = try await handle.outcome.value

            // 4. Check for child interruption — propagate as error
            if case let .interrupted(interruption) = outcome {
                throw HiveSubgraphError.childInterrupted(interruptID: interruption.interrupt.id)
            }

            // 5. Extract the child's final global store from the outcome
            let childStore: HiveGlobalStore<ChildSchema>
            switch outcome {
            case .finished(let output, _), .cancelled(let output, _), .outOfSteps(_, let output, _):
                guard case .fullStore(let store) = output else {
                    throw HiveSubgraphError.childOutputNotFullStore
                }
                childStore = store
            case .interrupted:
                // Already handled above; unreachable
                throw HiveSubgraphError.childOutputNotFullStore
            }

            // 6. Map child output -> parent writes
            let parentWrites = try outputMapping(outcome, childStore)

            return HiveNodeOutput(
                writes: parentWrites,
                next: .useGraphEdges
            )
        }
    }
}

extension Subgraph: _WorkflowStartNodesProviding {
    func _declaredStartNodes() -> [HiveNodeID] {
        isStart ? [id] : []
    }
}
