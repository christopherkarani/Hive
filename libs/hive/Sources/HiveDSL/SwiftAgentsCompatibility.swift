import Foundation

// MARK: - SwiftAgents-Style Shims

public extension Branch {
    /// SwiftAgents-style spelling of `Branch.case(...)` without backticks.
    static func when(
        name: String,
        _ condition: @escaping @Sendable (HiveStoreView<Schema>) -> Bool,
        @EffectsBuilder<Schema> _ body: @escaping @Sendable () -> HiveNodeOutput<Schema>
    ) -> Item {
        Self.`case`(name: name, when: condition, body)
    }

    /// SwiftAgents-style spelling of `Branch.default { ... }` without backticks.
    static func otherwise(
        @EffectsBuilder<Schema> _ body: @escaping @Sendable () -> HiveNodeOutput<Schema>
    ) -> Item {
        Self.`default`(body)
    }
}

// MARK: - Fan-Out + Join Helper

public enum FanOutCompilationError: Error, Sendable, Equatable {
    case targetsEmpty(from: HiveNodeID, join: HiveNodeID)
}

/// Declares a fan-out from a node to multiple targets, optionally followed by a join.
///
/// This is a convenience wrapper around `Edge` + `Join` for SwiftAgents-style "parallel" wiring.
public struct FanOut<Schema: HiveSchema>: WorkflowComponent, Sendable {
    private let from: HiveNodeID
    private let targets: [HiveNodeID]
    private let join: HiveNodeID?

    public init(from: String, to targets: [String], joinTo join: String? = nil) {
        self.from = HiveNodeID(from)
        self.targets = targets.map(HiveNodeID.init)
        self.join = join.map(HiveNodeID.init)
    }

    public init(
        from: String,
        joinTo join: String? = nil,
        @TargetsBuilder _ targets: () -> [String]
    ) {
        self.init(from: from, to: targets(), joinTo: join)
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        if targets.isEmpty, let join {
            throw FanOutCompilationError.targetsEmpty(from: from, join: join)
        }

        for target in targets {
            builder.addEdge(from: from, to: target)
        }

        if let join {
            builder.addJoinEdge(parents: targets, target: join)
        }
    }

    @resultBuilder
    public enum TargetsBuilder {
        public static func buildBlock(_ components: [String]...) -> [String] { components.flatMap(\.self) }
        public static func buildExpression(_ expression: String) -> [String] { [expression] }
        public static func buildOptional(_ component: [String]?) -> [String] { component ?? [] }
        public static func buildEither(first component: [String]) -> [String] { component }
        public static func buildEither(second component: [String]) -> [String] { component }
        public static func buildArray(_ components: [[String]]) -> [String] { components.flatMap(\.self) }
    }
}

// MARK: - Sequential Edge Helper

/// Declares a sequential chain of edges connecting the provided node IDs.
public struct SequenceEdges<Schema: HiveSchema>: WorkflowComponent, Sendable {
    private let nodes: [HiveNodeID]

    public init(_ nodes: [String]) {
        self.nodes = nodes.map(HiveNodeID.init)
    }

    public init(_ nodes: String...) {
        self.init(nodes)
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        guard nodes.count > 1 else { return }
        for index in 1..<nodes.count {
            builder.addEdge(from: nodes[index - 1], to: nodes[index])
        }
    }
}

