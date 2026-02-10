/// SwiftUI-style blueprint for composing workflow components.
public protocol WorkflowBlueprint: WorkflowComponent {
    associatedtype Body: WorkflowComponent where Body.Schema == Schema

    /// Declarative workflow body.
    @WorkflowBuilder<Schema> var body: Body { get }
}

public extension WorkflowBlueprint {
    /// Applies the composed body to a graph builder.
    func apply(to builder: inout HiveGraphBuilder<Schema>, design: inout WorkflowDesign) throws {
        try body.apply(to: &builder, design: &design)
    }
}
