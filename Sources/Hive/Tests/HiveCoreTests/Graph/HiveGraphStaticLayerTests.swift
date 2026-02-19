import Testing
@testable import HiveCore

private enum StaticLayerTestSchema: HiveSchema {
    static let channelSpecs: [AnyHiveChannelSpec<StaticLayerTestSchema>] = []
}

@Suite("HiveGraphBuilder static layer analysis")
struct HiveGraphStaticLayerTests {
    @Test("compile computes static layer depths for DAG")
    func compileComputesStaticLayersForDAG() throws {
        let a = HiveNodeID("A")
        let b = HiveNodeID("B")
        let c = HiveNodeID("C")
        let d = HiveNodeID("D")
        let e = HiveNodeID("E")

        var builder = HiveGraphBuilder<StaticLayerTestSchema>(start: [a])
        builder.addNode(a) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addNode(b) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addNode(c) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addNode(d) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addNode(e) { _ in HiveNodeOutput(writes: [], next: .end) }

        builder.addEdge(from: a, to: b)
        builder.addEdge(from: a, to: c)
        builder.addEdge(from: b, to: d)
        builder.addEdge(from: c, to: d)
        builder.addEdge(from: d, to: e)

        let compiled = try builder.compile()
        #expect(compiled.staticLayersByNodeID[a] == 0)
        #expect(compiled.staticLayersByNodeID[b] == 1)
        #expect(compiled.staticLayersByNodeID[c] == 1)
        #expect(compiled.staticLayersByNodeID[d] == 2)
        #expect(compiled.staticLayersByNodeID[e] == 3)
        #expect(compiled.maxStaticDepth == 3)
    }

    @Test("compile throws staticGraphCycleDetected for static-edge cycles")
    func compileThrowsForStaticCycle() {
        let a = HiveNodeID("A")
        let b = HiveNodeID("B")

        var builder = HiveGraphBuilder<StaticLayerTestSchema>(start: [a])
        builder.addNode(a) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addNode(b) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addEdge(from: a, to: b)
        builder.addEdge(from: b, to: a)

        do {
            _ = try builder.compile()
            #expect(Bool(false))
        } catch let error as HiveCompilationError {
            switch error {
            case .staticGraphCycleDetected(let nodes):
                #expect(nodes == [a, b])
            default:
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test("router-only cycle is not treated as static cycle")
    func routerOnlyCycleDoesNotThrowStaticCycleError() throws {
        let a = HiveNodeID("A")

        var builder = HiveGraphBuilder<StaticLayerTestSchema>(start: [a])
        builder.addNode(a) { _ in HiveNodeOutput(writes: [], next: .end) }
        builder.addRouter(from: a) { _ in
            .nodes([a])
        }

        let compiled = try builder.compile()
        #expect(compiled.staticLayersByNodeID[a] == 0)
        #expect(compiled.maxStaticDepth == 0)
    }
}
