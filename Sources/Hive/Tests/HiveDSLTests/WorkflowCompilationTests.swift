import Testing
import HiveDSL

@Test("Workflow start nodes preserve declaration order")
func workflowStartNodesPreserveDeclarationOrder() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let workflow = Workflow<Schema> {
        Node("A") { _ in Effects { End() } }.start()
        Node("B") { _ in Effects { End() } }.start()
    }

    let graph = try workflow.compile()
    #expect(graph.start == [HiveNodeID("A"), HiveNodeID("B")])
}

@Test("Chain emits edges in order")
func chainEmitsEdgesInOrder() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let workflow = Workflow<Schema> {
        Node("A") { _ in Effects { End() } }.start()
        Node("B") { _ in Effects { End() } }
        Node("C") { _ in Effects { End() } }

        Chain {
            Chain.Link.start("A")
            Chain.Link.then("B")
            Chain.Link.then("C")
        }
    }

    let graph = try workflow.compile()
    #expect(graph.staticEdgesByFrom[HiveNodeID("A")] == [HiveNodeID("B")])
    #expect(graph.staticEdgesByFrom[HiveNodeID("B")] == [HiveNodeID("C")])
}

@Test("Join edges preserve insertion order")
func joinEdgesPreserveInsertionOrder() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let workflow = Workflow<Schema> {
        Node("A") { _ in Effects { End() } }.start()
        Node("B") { _ in Effects { End() } }
        Node("J1") { _ in Effects { End() } }
        Node("J2") { _ in Effects { End() } }

        Join(parents: ["A"], to: "J1")
        Join(parents: ["B"], to: "J2")
    }

    let graph = try workflow.compile()
    let targets = graph.joinEdges.map(\.target)
    #expect(targets == [HiveNodeID("J1"), HiveNodeID("J2")])
}

@Test("Branch compiles to a builder router and falls back to useGraphEdges")
func branchFallsBackToUseGraphEdges() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { 0 },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))

    struct NoopClock: HiveClock {
        func nowNanoseconds() -> UInt64 { 0 }
        func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
    }

    struct NoopLogger: HiveLogger {
        func debug(_ message: String, metadata: [String: String]) {}
        func info(_ message: String, metadata: [String: String]) {}
        func error(_ message: String, metadata: [String: String]) {}
    }

    let workflow = Workflow<Schema> {
        Node("A") { _ in
            Effects {
                Set(valueKey, 0)
                UseGraphEdges()
            }
        }.start()
        Node("X") { _ in Effects { End() } }
        Node("Y") { _ in Effects { End() } }

        Edge("A", to: "Y")

        Branch(from: "A") {
            Branch.case(name: "value==1", when: { view in
                (try? view.get(valueKey)) == 1
            }) {
                GoTo("X")
            }

            Branch.default {
                UseGraphEdges()
            }
        }
    }

    let graph = try workflow.compile()
    let environment = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger()
    )
    let runtime = try HiveRuntime(graph: graph, environment: environment)

    let handle = await runtime.run(threadID: HiveThreadID("t1"), input: (), options: HiveRunOptions())

    var step1Started: [HiveNodeID] = []
    for try await event in handle.events {
        guard case let .taskStarted(node, _) = event.kind else { continue }
        if event.id.stepIndex == 1 {
            step1Started.append(node)
        }
    }

    _ = try await handle.outcome.value

    #expect(step1Started == [HiveNodeID("Y")])
}
