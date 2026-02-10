import Foundation

public struct WorkflowDesign: Sendable {
    public init() {}
}

/// Bundle containing the compiled graph and design metadata for a workflow.
public struct WorkflowBundle<Schema: HiveSchema>: Sendable {
    /// Compiled graph ready for execution.
    public let graph: CompiledHiveGraph<Schema>
    /// Design-time metadata captured during DSL assembly.
    public let design: WorkflowDesign

    /// Creates a bundle with the provided graph and design metadata.
    public init(graph: CompiledHiveGraph<Schema>, design: WorkflowDesign) {
        self.graph = graph
        self.design = design
    }
}

public protocol WorkflowComponent: Sendable {
    associatedtype Schema: HiveSchema

    func apply(to builder: inout HiveGraphBuilder<Schema>, design: inout WorkflowDesign) throws
}

public struct AnyWorkflowComponent<Schema: HiveSchema>: WorkflowComponent {
    private let _apply: @Sendable (inout HiveGraphBuilder<Schema>, inout WorkflowDesign) throws -> Void
    private let _declaredStartNodes: [HiveNodeID]

    public init<Component: WorkflowComponent>(_ component: Component) where Component.Schema == Schema {
        self._apply = { builder, design in
            try component.apply(to: &builder, design: &design)
        }
        self._declaredStartNodes = (component as? any _WorkflowStartNodesProviding)?._declaredStartNodes() ?? []
    }

    public init(
        startNodes: [HiveNodeID] = [],
        apply: @escaping @Sendable (inout HiveGraphBuilder<Schema>, inout WorkflowDesign) throws -> Void
    ) {
        self._declaredStartNodes = startNodes
        self._apply = apply
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design: inout WorkflowDesign) throws {
        try _apply(&builder, &design)
    }

    func _startNodes() -> [HiveNodeID] {
        _declaredStartNodes
    }
}

@resultBuilder
public enum WorkflowBuilder<Schema: HiveSchema> {
    public static func buildExpression<Component: WorkflowComponent>(_ expression: Component) -> AnyWorkflowComponent<Schema>
    where Component.Schema == Schema {
        AnyWorkflowComponent(expression)
    }

    public static func buildExpression(_ expression: AnyWorkflowComponent<Schema>) -> AnyWorkflowComponent<Schema> {
        expression
    }

    public static func buildBlock(_ components: AnyWorkflowComponent<Schema>...) -> AnyWorkflowComponent<Schema> {
        WorkflowGroup(children: components).eraseToAny()
    }

    public static func buildOptional(_ component: AnyWorkflowComponent<Schema>?) -> AnyWorkflowComponent<Schema> {
        component ?? AnyWorkflowComponent(apply: { _, _ in })
    }

    public static func buildEither(first component: AnyWorkflowComponent<Schema>) -> AnyWorkflowComponent<Schema> {
        component
    }

    public static func buildEither(second component: AnyWorkflowComponent<Schema>) -> AnyWorkflowComponent<Schema> {
        component
    }

    public static func buildArray(_ components: [AnyWorkflowComponent<Schema>]) -> AnyWorkflowComponent<Schema> {
        WorkflowGroup(children: components).eraseToAny()
    }
}

public struct Workflow<Schema: HiveSchema>: Sendable {
    private let root: AnyWorkflowComponent<Schema>

    public init(@WorkflowBuilder<Schema> _ content: () -> AnyWorkflowComponent<Schema>) {
        self.root = content()
    }

    /// Compiles the workflow into a runnable graph.
    public func compile(graphVersionOverride: String? = nil) throws -> CompiledHiveGraph<Schema> {
        try bundle(graphVersionOverride: graphVersionOverride).graph
    }

    /// Compiles the workflow and returns the compiled graph plus design metadata.
    public func bundle(graphVersionOverride: String? = nil) throws -> WorkflowBundle<Schema> {
        var design = WorkflowDesign()
        var builder = HiveGraphBuilder<Schema>(start: root._startNodes())
        try root.apply(to: &builder, design: &design)
        let graph = try builder.compile(graphVersionOverride: graphVersionOverride)
        return WorkflowBundle(graph: graph, design: design)
    }
}

// MARK: - Internals

protocol _WorkflowStartNodesProviding {
    func _declaredStartNodes() -> [HiveNodeID]
}

private struct WorkflowGroup<Schema: HiveSchema>: WorkflowComponent, _WorkflowStartNodesProviding {
    private let children: [AnyWorkflowComponent<Schema>]

    init(children: [AnyWorkflowComponent<Schema>]) {
        self.children = children
    }

    func apply(to builder: inout HiveGraphBuilder<Schema>, design: inout WorkflowDesign) throws {
        for child in children {
            try child.apply(to: &builder, design: &design)
        }
    }

    func _declaredStartNodes() -> [HiveNodeID] {
        children.flatMap { $0._startNodes() }
    }

    func eraseToAny() -> AnyWorkflowComponent<Schema> {
        AnyWorkflowComponent(
            startNodes: _declaredStartNodes(),
            apply: { builder, design in
                try self.apply(to: &builder, design: &design)
            }
        )
    }
}
