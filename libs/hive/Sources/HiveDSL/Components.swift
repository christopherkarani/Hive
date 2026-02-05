import Foundation

public enum HiveDSLCompilationError: Error, Sendable {
    case branchDefaultMissing(from: HiveNodeID)
    case chainMissingStart
}

public struct Node<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public let id: HiveNodeID
    public let retryPolicy: HiveRetryPolicy

    private let isStart: Bool
    private let run: HiveNode<Schema>

    public init(_ id: String, retryPolicy: HiveRetryPolicy = .none, _ run: @escaping HiveNode<Schema>) {
        self.id = HiveNodeID(id)
        self.retryPolicy = retryPolicy
        self.isStart = false
        self.run = run
    }

    private init(id: HiveNodeID, retryPolicy: HiveRetryPolicy, isStart: Bool, run: @escaping HiveNode<Schema>) {
        self.id = id
        self.retryPolicy = retryPolicy
        self.isStart = isStart
        self.run = run
    }

    public func start() -> Node<Schema> {
        Node(id: id, retryPolicy: retryPolicy, isStart: true, run: run)
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        builder.addNode(id, retryPolicy: retryPolicy, run)
    }
}

extension Node: _WorkflowStartNodesProviding {
    func _declaredStartNodes() -> [HiveNodeID] {
        isStart ? [id] : []
    }
}

public struct Edge<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public let from: HiveNodeID
    public let to: HiveNodeID

    public init(_ from: String, to: String) {
        self.from = HiveNodeID(from)
        self.to = HiveNodeID(to)
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        builder.addEdge(from: from, to: to)
    }
}

public struct Join<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public let parents: [HiveNodeID]
    public let target: HiveNodeID

    public init(parents: [String], to target: String) {
        self.parents = parents.map(HiveNodeID.init)
        self.target = HiveNodeID(target)
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        builder.addJoinEdge(parents: parents, target: target)
    }
}

public struct Chain<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public enum Link: Sendable {
        case start(String)
        case then(String)
    }

    private let links: [Link]

    public init(@Builder _ content: () -> [Link]) {
        self.links = content()
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        var current: HiveNodeID?
        for link in links {
            switch link {
            case .start(let id):
                current = HiveNodeID(id)
            case .then(let id):
                guard let from = current else {
                    throw HiveDSLCompilationError.chainMissingStart
                }
                let to = HiveNodeID(id)
                builder.addEdge(from: from, to: to)
                current = to
            }
        }
    }

    @resultBuilder
    public enum Builder {
        public static func buildBlock(_ components: Link...) -> [Link] { components }
        public static func buildExpression(_ expression: Link) -> Link { expression }
        public static func buildOptional(_ component: [Link]?) -> [Link] { component ?? [] }
        public static func buildEither(first component: [Link]) -> [Link] { component }
        public static func buildEither(second component: [Link]) -> [Link] { component }
        public static func buildArray(_ components: [[Link]]) -> [Link] { components.flatMap { $0 } }
    }
}

public struct Branch<Schema: HiveSchema>: WorkflowComponent, Sendable {
    public enum Item: Sendable {
        case route(RouteCase)
        case `default`(DefaultCase)
    }

    public struct RouteCase: Sendable {
        public let name: String
        public let when: @Sendable (HiveStoreView<Schema>) -> Bool
        public let next: @Sendable () -> HiveNext
    }

    public struct DefaultCase: Sendable {
        public let next: @Sendable () -> HiveNext
    }

    private let from: HiveNodeID
    private let items: [Item]

    public init(from: String, @Builder _ content: () -> [Item]) {
        self.from = HiveNodeID(from)
        self.items = content()
    }

    public func apply(to builder: inout HiveGraphBuilder<Schema>, design _: inout WorkflowDesign) throws {
        let hasDefault = items.contains { item in
            if case .default = item { return true }
            return false
        }
        guard hasDefault else {
            throw HiveDSLCompilationError.branchDefaultMissing(from: from)
        }

        let items = self.items
        builder.addRouter(from: from) { view in
            for item in items {
                switch item {
                case .route(let routeCase):
                    if routeCase.when(view) {
                        return routeCase.next()._hiveDSLNormalized
                    }
                case .default(let defaultCase):
                    return defaultCase.next()._hiveDSLNormalized
                }
            }
            return .useGraphEdges
        }
    }

    public static func `case`(
        name: String,
        when: @escaping @Sendable (HiveStoreView<Schema>) -> Bool,
        @EffectsBuilder<Schema> _ body: @escaping @Sendable () -> HiveNodeOutput<Schema>
    ) -> Item {
        .route(
            RouteCase(
                name: name,
                when: when,
                next: { body().next }
            )
        )
    }

    public static func `default`(
        @EffectsBuilder<Schema> _ body: @escaping @Sendable () -> HiveNodeOutput<Schema>
    ) -> Item {
        .default(DefaultCase(next: { body().next }))
    }

    @resultBuilder
    public enum Builder {
        public static func buildBlock(_ components: Item...) -> [Item] { components }
        public static func buildExpression(_ expression: Item) -> Item { expression }
        public static func buildOptional(_ component: [Item]?) -> [Item] { component ?? [] }
        public static func buildEither(first component: [Item]) -> [Item] { component }
        public static func buildEither(second component: [Item]) -> [Item] { component }
        public static func buildArray(_ components: [[Item]]) -> [Item] { components.flatMap { $0 } }
    }
}
