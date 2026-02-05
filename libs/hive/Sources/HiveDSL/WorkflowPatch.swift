import Foundation

/// Represents a static edge in a workflow for diff reporting.
public struct WorkflowEdge: Hashable, Sendable {
    public let from: HiveNodeID
    public let to: HiveNodeID

    public init(from: HiveNodeID, to: HiveNodeID) {
        self.from = from
        self.to = to
    }
}

/// Structured diff describing changes applied to a workflow graph.
public struct WorkflowDiff: Sendable {
    public let addedNodes: [HiveNodeID]
    public let removedNodes: [HiveNodeID]
    public let updatedNodes: [HiveNodeID]
    public let addedEdges: [WorkflowEdge]
    public let removedEdges: [WorkflowEdge]

    public init(
        addedNodes: [HiveNodeID] = [],
        removedNodes: [HiveNodeID] = [],
        updatedNodes: [HiveNodeID] = [],
        addedEdges: [WorkflowEdge] = [],
        removedEdges: [WorkflowEdge] = []
    ) {
        self.addedNodes = addedNodes
        self.removedNodes = removedNodes
        self.updatedNodes = updatedNodes
        self.addedEdges = addedEdges
        self.removedEdges = removedEdges
    }

    /// Renders a deterministic Mermaid diff summary using comment annotations.
    public func renderMermaid() -> String {
        var lines: [String] = ["flowchart TD"]
        appendSection(title: "Added Nodes", nodes: addedNodes, prefix: "+", into: &lines)
        appendSection(title: "Removed Nodes", nodes: removedNodes, prefix: "-", into: &lines)
        appendSection(title: "Updated Nodes", nodes: updatedNodes, prefix: "~", into: &lines)
        appendSection(title: "Added Edges", edges: addedEdges, prefix: "+", into: &lines)
        appendSection(title: "Removed Edges", edges: removedEdges, prefix: "-", into: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendSection(title: String, nodes: [HiveNodeID], prefix: String, into lines: inout [String]) {
        guard !nodes.isEmpty else { return }
        lines.append("%% \(title)")
        let sorted = nodes.sorted { lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        for node in sorted {
            lines.append("%% \(prefix) \(node.rawValue)")
        }
    }

    private func appendSection(title: String, edges: [WorkflowEdge], prefix: String, into lines: inout [String]) {
        guard !edges.isEmpty else { return }
        lines.append("%% \(title)")
        let sorted = edges.sorted { lhs, rhs in
            if lexicographicallyPrecedes(lhs.from.rawValue, rhs.from.rawValue) { return true }
            if lexicographicallyPrecedes(rhs.from.rawValue, lhs.from.rawValue) { return false }
            return lexicographicallyPrecedes(lhs.to.rawValue, rhs.to.rawValue)
        }
        for edge in sorted {
            lines.append("%% \(prefix) \(edge.from.rawValue)-->\(edge.to.rawValue)")
        }
    }
}

/// Errors raised when applying a workflow patch.
public enum WorkflowPatchError: Error, Sendable {
    case unknownNode(HiveNodeID)
    case duplicateNodeID(HiveNodeID)
    case missingStaticEdge(from: HiveNodeID, to: HiveNodeID)
}

/// Result of applying a patch: the new graph plus a diff summary.
public struct WorkflowPatchResult<Schema: HiveSchema>: Sendable {
    public let graph: CompiledHiveGraph<Schema>
    public let diff: WorkflowDiff

    public init(graph: CompiledHiveGraph<Schema>, diff: WorkflowDiff) {
        self.graph = graph
        self.diff = diff
    }
}

/// Declarative patch operations for updating a compiled workflow graph.
public struct WorkflowPatch<Schema: HiveSchema>: Sendable {
    private enum Operation: Sendable {
        case replaceNode(id: HiveNodeID, retryPolicy: HiveRetryPolicy, run: HiveNode<Schema>)
        case insertProbe(id: HiveNodeID, from: HiveNodeID, to: HiveNodeID, retryPolicy: HiveRetryPolicy, run: HiveNode<Schema>)
    }

    private var operations: [Operation] = []

    public init() {}

    /// Replaces a node implementation while preserving its ID.
    public mutating func replaceNode(
        _ id: String,
        retryPolicy: HiveRetryPolicy = .none,
        _ run: @escaping HiveNode<Schema>
    ) {
        operations.append(.replaceNode(id: HiveNodeID(id), retryPolicy: retryPolicy, run: run))
    }

    /// Inserts a probe node between two static edges (`from` → `to`).
    /// Only static edges are modified; routers and joins are not affected.
    public mutating func insertProbe(
        _ id: String,
        between from: String,
        and to: String,
        retryPolicy: HiveRetryPolicy = .none,
        _ run: @escaping HiveNode<Schema>
    ) {
        operations.append(
            .insertProbe(
                id: HiveNodeID(id),
                from: HiveNodeID(from),
                to: HiveNodeID(to),
                retryPolicy: retryPolicy,
                run: run
            )
        )
    }

    /// Applies the patch to a compiled graph and returns the patched graph plus diff.
    public func apply(to graph: CompiledHiveGraph<Schema>) throws -> WorkflowPatchResult<Schema> {
        var nodesByID = graph.nodesByID
        var staticEdgesByFrom = graph.staticEdgesByFrom
        let joinEdges = graph.joinEdges
        let routersByFrom = graph.routersByFrom
        let startNodes = graph.start
        let outputProjection = graph.outputProjection

        var addedNodes: [HiveNodeID] = []
        let removedNodes: [HiveNodeID] = []
        var updatedNodes: [HiveNodeID] = []
        var addedEdges: [WorkflowEdge] = []
        var removedEdges: [WorkflowEdge] = []

        var addedNodeSet: Set<HiveNodeID> = []
        var updatedNodeSet: Set<HiveNodeID> = []
        var addedEdgeSet: Set<WorkflowEdge> = []
        var removedEdgeSet: Set<WorkflowEdge> = []

        func recordAddedNode(_ id: HiveNodeID) {
            if addedNodeSet.insert(id).inserted { addedNodes.append(id) }
        }
        func recordUpdatedNode(_ id: HiveNodeID) {
            if updatedNodeSet.insert(id).inserted { updatedNodes.append(id) }
        }
        func recordAddedEdge(_ edge: WorkflowEdge) {
            if addedEdgeSet.insert(edge).inserted { addedEdges.append(edge) }
        }
        func recordRemovedEdge(_ edge: WorkflowEdge) {
            if removedEdgeSet.insert(edge).inserted { removedEdges.append(edge) }
        }

        for operation in operations {
            switch operation {
            case .replaceNode(let id, let retryPolicy, let run):
                guard nodesByID[id] != nil else {
                    throw WorkflowPatchError.unknownNode(id)
                }
                nodesByID[id] = HiveCompiledNode(id: id, retryPolicy: retryPolicy, run: run)
                recordUpdatedNode(id)
            case .insertProbe(let id, let from, let to, let retryPolicy, let run):
                guard nodesByID[id] == nil else {
                    throw WorkflowPatchError.duplicateNodeID(id)
                }
                guard nodesByID[from] != nil else {
                    throw WorkflowPatchError.unknownNode(from)
                }
                guard nodesByID[to] != nil else {
                    throw WorkflowPatchError.unknownNode(to)
                }
                guard var edges = staticEdgesByFrom[from],
                      let index = edges.firstIndex(of: to) else {
                    throw WorkflowPatchError.missingStaticEdge(from: from, to: to)
                }

                edges[index] = id
                staticEdgesByFrom[from] = edges
                staticEdgesByFrom[id] = [to]
                nodesByID[id] = HiveCompiledNode(id: id, retryPolicy: retryPolicy, run: run)

                recordAddedNode(id)
                recordRemovedEdge(WorkflowEdge(from: from, to: to))
                recordAddedEdge(WorkflowEdge(from: from, to: id))
                recordAddedEdge(WorkflowEdge(from: id, to: to))
            }
        }

        let rebuilt = try Self.rebuildGraph(
            startNodes: startNodes,
            nodesByID: nodesByID,
            staticEdgesByFrom: staticEdgesByFrom,
            joinEdges: joinEdges,
            routersByFrom: routersByFrom,
            outputProjection: outputProjection
        )

        let diff = WorkflowDiff(
            addedNodes: addedNodes,
            removedNodes: removedNodes,
            updatedNodes: updatedNodes,
            addedEdges: addedEdges,
            removedEdges: removedEdges
        )

        return WorkflowPatchResult(graph: rebuilt, diff: diff)
    }

    private static func rebuildGraph(
        startNodes: [HiveNodeID],
        nodesByID: [HiveNodeID: HiveCompiledNode<Schema>],
        staticEdgesByFrom: [HiveNodeID: [HiveNodeID]],
        joinEdges: [HiveJoinEdge],
        routersByFrom: [HiveNodeID: HiveRouter<Schema>],
        outputProjection: HiveOutputProjection
    ) throws -> CompiledHiveGraph<Schema> {
        var builder = HiveGraphBuilder<Schema>(start: startNodes)
        let sortedNodeIDs = nodesByID.keys.sorted { lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        for id in sortedNodeIDs {
            if let node = nodesByID[id] {
                builder.addNode(id, retryPolicy: node.retryPolicy, node.run)
            }
        }

        let sortedFrom = staticEdgesByFrom.keys.sorted { lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        for from in sortedFrom {
            if let targets = staticEdgesByFrom[from] {
                for to in targets {
                    builder.addEdge(from: from, to: to)
                }
            }
        }

        let sortedJoins = joinEdges.sorted { lexicographicallyPrecedes($0.id, $1.id) }
        for join in sortedJoins {
            builder.addJoinEdge(parents: join.parents, target: join.target)
        }

        let sortedRouters = routersByFrom.keys.sorted { lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        for from in sortedRouters {
            if let router = routersByFrom[from] {
                builder.addRouter(from: from, router)
            }
        }

        builder.setOutputProjection(outputProjection)
        return try builder.compile()
    }
}

private func lexicographicallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}
