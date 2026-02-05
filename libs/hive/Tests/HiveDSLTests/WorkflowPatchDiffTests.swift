import Testing
import HiveDSL

private enum PatchSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
}

private func noopNode() -> HiveNode<PatchSchema> {
    { _ in HiveNodeOutput() }
}

private func makeNode(_ id: String) -> Node<PatchSchema> {
    Node(id, retryPolicy: .none, noopNode())
}

@Test("Patch replacing node preserves IDs and produces diff")
func patchReplacingNodePreservesIDsAndProducesDiff() throws {
    let workflow = Workflow<PatchSchema> {
        makeNode("A").start()
        makeNode("B")
        Edge("A", to: "B")
    }

    let graph = try workflow.compile()

    var patch = WorkflowPatch<PatchSchema>()
    patch.replaceNode("B", retryPolicy: .none, noopNode())

    let result = try patch.apply(to: graph)

    #expect(result.graph.nodesByID[HiveNodeID("B")] != nil)
    #expect(result.diff.updatedNodes.contains(HiveNodeID("B")))
}

@Test("Patch inserting probe updates edges deterministically")
func patchInsertingProbeUpdatesEdgesDeterministically() throws {
    let workflow = Workflow<PatchSchema> {
        makeNode("A").start()
        makeNode("B")
        makeNode("C")
        Edge("A", to: "B")
        Edge("A", to: "C")
    }

    let graph = try workflow.compile()

    var patch = WorkflowPatch<PatchSchema>()
    patch.insertProbe("Probe", between: "A", and: "B", retryPolicy: .none, noopNode())

    let result = try patch.apply(to: graph)

    let aEdges = result.graph.staticEdgesByFrom[HiveNodeID("A")] ?? []
    #expect(aEdges == [HiveNodeID("Probe"), HiveNodeID("C")])

    let probeEdges = result.graph.staticEdgesByFrom[HiveNodeID("Probe")] ?? []
    #expect(probeEdges == [HiveNodeID("B")])
}

@Test("Diff renders stable mermaid")
func diffRendersStableMermaid() throws {
    let workflow = Workflow<PatchSchema> {
        makeNode("A").start()
        makeNode("B")
        Edge("A", to: "B")
    }

    let graph = try workflow.compile()

    var patch = WorkflowPatch<PatchSchema>()
    patch.insertProbe("Probe", between: "A", and: "B", retryPolicy: .none, noopNode())

    let result = try patch.apply(to: graph)
    let expected = """
    flowchart TD
    %% Added Nodes
    %% + Probe
    %% Added Edges
    %% + A-->Probe
    %% + Probe-->B
    %% Removed Edges
    %% - A-->B
    """

    #expect(result.diff.renderMermaid() == expected)
}
