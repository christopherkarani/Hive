/// Compiled node configuration used by the runtime.
public struct HiveCompiledNode<Schema: HiveSchema>: Sendable {
    public let id: HiveNodeID
    public let retryPolicy: HiveRetryPolicy
    public let run: HiveNode<Schema>

    public init(id: HiveNodeID, retryPolicy: HiveRetryPolicy, run: @escaping HiveNode<Schema>) {
        self.id = id
        self.retryPolicy = retryPolicy
        self.run = run
    }
}

struct HiveStaticEdge: Hashable, Sendable {
    let from: HiveNodeID
    let to: HiveNodeID
}

/// Join edge with canonical ID and sorted parent list.
public struct HiveJoinEdge: Hashable, Sendable {
    public let id: String
    public let parents: [HiveNodeID]
    public let target: HiveNodeID

    public init(parents: [HiveNodeID], target: HiveNodeID) {
        let sorted = parents.sorted { HiveOrdering.lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        self.parents = sorted
        self.target = target
        self.id = HiveJoinEdge.canonicalID(parents: sorted, target: target)
    }

    static func canonicalID(parents: [HiveNodeID], target: HiveNodeID) -> String {
        let parentIDs = parents.map { $0.rawValue }.joined(separator: "+")
        return "join:\(parentIDs):\(target.rawValue)"
    }
}

/// Fully compiled, validated graph for execution.
public struct CompiledHiveGraph<Schema: HiveSchema>: Sendable {
    public let schemaVersion: String
    public let graphVersion: String
    public let start: [HiveNodeID]
    public let outputProjection: HiveOutputProjection
    public let nodesByID: [HiveNodeID: HiveCompiledNode<Schema>]
    let staticEdgesInOrder: [HiveStaticEdge]
    public let staticEdgesByFrom: [HiveNodeID: [HiveNodeID]]
    public let joinEdges: [HiveJoinEdge]
    public let routersByFrom: [HiveNodeID: HiveRouter<Schema>]
}

/// Builder for assembling and compiling graphs.
public struct HiveGraphBuilder<Schema: HiveSchema> {
    private var start: [HiveNodeID]
    private var nodes: [HiveNodeID: HiveCompiledNode<Schema>] = [:]
    private var nodeInsertions: [HiveNodeID] = []
    private var staticEdges: [(from: HiveNodeID, to: HiveNodeID)] = []
    private var joinEdges: [(parents: [HiveNodeID], target: HiveNodeID)] = []
    private var routers: [(from: HiveNodeID, router: HiveRouter<Schema>)] = []
    private var outputProjection: HiveOutputProjection = .fullStore

    public init(start: [HiveNodeID]) {
        self.start = start
    }

    public mutating func addNode(
        _ id: HiveNodeID,
        retryPolicy: HiveRetryPolicy = .none,
        _ node: @escaping HiveNode<Schema>
    ) {
        nodeInsertions.append(id)
        nodes[id] = HiveCompiledNode(id: id, retryPolicy: retryPolicy, run: node)
    }

    public mutating func addEdge(from: HiveNodeID, to: HiveNodeID) {
        staticEdges.append((from: from, to: to))
    }

    public mutating func addJoinEdge(parents: [HiveNodeID], target: HiveNodeID) {
        joinEdges.append((parents: parents, target: target))
    }

    public mutating func addRouter(from: HiveNodeID, _ router: @escaping HiveRouter<Schema>) {
        routers.append((from: from, router: router))
    }

    public mutating func setOutputProjection(_ projection: HiveOutputProjection) {
        outputProjection = projection
    }

    public func compile(graphVersionOverride: String? = nil) throws -> CompiledHiveGraph<Schema> {
        let registry = try HiveSchemaRegistry<Schema>()

        try validateGraphStructure()

        let normalizedProjection = outputProjection.normalized()
        try validateOutputProjection(normalizedProjection, registry: registry)

        var edgesByFrom: [HiveNodeID: [HiveNodeID]] = [:]
        for edge in staticEdges {
            edgesByFrom[edge.from, default: []].append(edge.to)
        }
        let staticEdgesInOrder = staticEdges.map { HiveStaticEdge(from: $0.from, to: $0.to) }

        var routersByFrom: [HiveNodeID: HiveRouter<Schema>] = [:]
        for entry in routers {
            routersByFrom[entry.from] = entry.router
        }

        let compiledJoinEdges = joinEdges.map { HiveJoinEdge(parents: $0.parents, target: $0.target) }

        let schemaVersion = HiveVersioning.schemaVersion(registry: registry)
        let graphVersion = graphVersionOverride ?? HiveVersioning.graphVersion(
            start: start,
            nodesByID: nodes,
            routerFrom: routers.map { $0.from },
            staticEdges: staticEdges,
            joinEdges: joinEdges,
            outputProjection: normalizedProjection
        )

        return CompiledHiveGraph(
            schemaVersion: schemaVersion,
            graphVersion: graphVersion,
            start: start,
            outputProjection: normalizedProjection,
            nodesByID: nodes,
            staticEdgesInOrder: staticEdgesInOrder,
            staticEdgesByFrom: edgesByFrom,
            joinEdges: compiledJoinEdges,
            routersByFrom: routersByFrom
        )
    }

    private func validateGraphStructure() throws {
        if start.isEmpty {
            throw HiveCompilationError.startEmpty
        }

        var startSeen: Set<HiveNodeID> = []
        for node in start {
            if startSeen.contains(node) {
                throw HiveCompilationError.duplicateStartNode(node)
            }
            startSeen.insert(node)
        }

        if let duplicateNode = smallestDuplicateNodeID() {
            throw HiveCompilationError.duplicateNodeID(duplicateNode)
        }

        if let invalidNode = smallestInvalidNodeID() {
            throw HiveCompilationError.invalidNodeIDContainsReservedJoinCharacters(nodeID: invalidNode)
        }

        for node in start {
            guard nodes[node] != nil else {
                throw HiveCompilationError.unknownStartNode(node)
            }
        }

        for edge in staticEdges {
            if nodes[edge.from] == nil {
                throw HiveCompilationError.unknownEdgeEndpoint(from: edge.from, to: edge.to, unknown: edge.from)
            }
            if nodes[edge.to] == nil {
                throw HiveCompilationError.unknownEdgeEndpoint(from: edge.from, to: edge.to, unknown: edge.to)
            }
        }

        var routersByFrom: Set<HiveNodeID> = []
        for entry in routers {
            if nodes[entry.from] == nil {
                throw HiveCompilationError.unknownRouterFrom(entry.from)
            }
            if routersByFrom.contains(entry.from) {
                throw HiveCompilationError.duplicateRouter(from: entry.from)
            }
            routersByFrom.insert(entry.from)
        }

        var seenJoinIDs: Set<String> = []
        for edge in joinEdges {
            let parents = edge.parents
            if parents.isEmpty {
                throw HiveCompilationError.invalidJoinEdgeParentsEmpty(target: edge.target)
            }

            var parentSeen: Set<HiveNodeID> = []
            for parent in parents {
                if parentSeen.contains(parent) {
                    throw HiveCompilationError.invalidJoinEdgeParentsContainsDuplicate(
                        parent: parent,
                        target: edge.target
                    )
                }
                parentSeen.insert(parent)
            }

            if parentSeen.contains(edge.target) {
                throw HiveCompilationError.invalidJoinEdgeParentsContainsTarget(target: edge.target)
            }

            for parent in parents {
                if nodes[parent] == nil {
                    throw HiveCompilationError.unknownJoinParent(parent: parent, target: edge.target)
                }
            }

            if nodes[edge.target] == nil {
                throw HiveCompilationError.unknownJoinTarget(target: edge.target)
            }

            let joinID = HiveJoinEdge.canonicalID(
                parents: parents.sorted { HiveOrdering.lexicographicallyPrecedes($0.rawValue, $1.rawValue) },
                target: edge.target
            )
            if seenJoinIDs.contains(joinID) {
                throw HiveCompilationError.duplicateJoinEdge(joinID: joinID)
            }
            seenJoinIDs.insert(joinID)
        }
    }

    private func smallestDuplicateNodeID() -> HiveNodeID? {
        var counts: [String: Int] = [:]
        for id in nodeInsertions {
            counts[id.rawValue, default: 0] += 1
        }
        var smallest: String?
        for (raw, count) in counts where count > 1 {
            if let current = smallest {
                if HiveOrdering.lexicographicallyPrecedes(raw, current) {
                    smallest = raw
                }
            } else {
                smallest = raw
            }
        }
        if let smallest {
            return HiveNodeID(smallest)
        }
        return nil
    }

    private func smallestInvalidNodeID() -> HiveNodeID? {
        var smallest: String?
        for id in nodeInsertions {
            let raw = id.rawValue
            if raw.contains(":") || raw.contains("+") {
                if let current = smallest {
                    if HiveOrdering.lexicographicallyPrecedes(raw, current) {
                        smallest = raw
                    }
                } else {
                    smallest = raw
                }
            }
        }
        if let smallest {
            return HiveNodeID(smallest)
        }
        return nil
    }

    private func validateOutputProjection(
        _ projection: HiveOutputProjection,
        registry: HiveSchemaRegistry<Schema>
    ) throws {
        switch projection {
        case .fullStore:
            return
        case .channels(let ids):
            for id in ids {
                guard let spec = registry.channelSpecsByID[id] else {
                    throw HiveCompilationError.outputProjectionUnknownChannel(id)
                }
                if spec.scope == .taskLocal {
                    throw HiveCompilationError.outputProjectionIncludesTaskLocal(id)
                }
            }
        }
    }
}
