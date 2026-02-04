/// Identifier for a graph node.
public struct HiveNodeID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Routing decision for the next frontier.
public enum HiveNext: Sendable {
    case useGraphEdges
    case end
    case nodes([HiveNodeID])

    var normalized: HiveNext {
        switch self {
        case .nodes(let nodes) where nodes.isEmpty:
            return .end
        default:
            return self
        }
    }
}

/// Deterministic router used to select next nodes for a task.
public typealias HiveRouter<Schema: HiveSchema> = @Sendable (HiveStoreView<Schema>) -> HiveNext
