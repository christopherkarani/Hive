import Foundation
import Testing
@testable import HiveCore

private enum TinyGraphSchema: HiveSchema {
    enum Channels {
        static let x = HiveChannelKey<TinyGraphSchema, Int>(HiveChannelID("x"))
        static let y = HiveChannelKey<TinyGraphSchema, Int>(HiveChannelID("y"))
    }

    static let channelSpecs: [AnyHiveChannelSpec<TinyGraphSchema>] = [
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.x,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { 0 },
                persistence: .untracked
            )
        ),
        AnyHiveChannelSpec(
            HiveChannelSpec(
                key: Channels.y,
                scope: .global,
                reducer: .lastWriteWins(),
                initial: { 0 },
                persistence: .untracked
            )
        ),
    ]
}

private func compileTinyGraph() throws -> CompiledHiveGraph<TinyGraphSchema> {
    let a = HiveNodeID("A")
    let b = HiveNodeID("B")
    let c = HiveNodeID("C")
    let j = HiveNodeID("J")

    var builder = HiveGraphBuilder<TinyGraphSchema>(start: [a])

    // Intentionally insert nodes out of lexicographic order so `HiveGraphDescription.nodes` can prove sorting.
    builder.addNode(b) { input in HiveNodeOutput(writes: [], next: .end) }
    builder.addNode(a) { input in HiveNodeOutput(writes: [], next: .end) }
    builder.addNode(j) { input in HiveNodeOutput(writes: [], next: .end) }
    builder.addNode(c) { input in HiveNodeOutput(writes: [], next: .end) }

    builder.addEdge(from: a, to: b)
    builder.addEdge(from: a, to: c)

    builder.addJoinEdge(parents: [c, b], target: j)

    builder.addRouter(from: a) { _ in
        .nodes([b, c])
    }

    builder.setOutputProjection(.channels([HiveChannelID("y"), HiveChannelID("x"), HiveChannelID("x")]))

    return try builder.compile()
}

@Test
func graphDescription_GoldenJSON() throws {
    let compiled = try compileTinyGraph()
    let description = compiled.graphDescription()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(description)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json == """
    {
      "graphVersion" : "345869ef0a16d32c9126ed343d309063e279988b4a44e7cc6e71921e97020fe1",
      "joinEdges" : [
        {
          "id" : "join:B+C:J",
          "parents" : [
            {
              "rawValue" : "B"
            },
            {
              "rawValue" : "C"
            }
          ],
          "target" : {
            "rawValue" : "J"
          }
        }
      ],
      "nodes" : [
        {
          "rawValue" : "A"
        },
        {
          "rawValue" : "B"
        },
        {
          "rawValue" : "C"
        },
        {
          "rawValue" : "J"
        }
      ],
      "outputProjection" : {
        "channels" : [
          "x",
          "y"
        ]
      },
      "routers" : [
        {
          "rawValue" : "A"
        }
      ],
      "schemaVersion" : "6f7c4aa33eca01550f89bf3f30d5262681907db90db38f99e974c1daed2ec2b9",
      "start" : [
        {
          "rawValue" : "A"
        }
      ],
      "staticEdges" : [
        {
          "from" : {
            "rawValue" : "A"
          },
          "to" : {
            "rawValue" : "B"
          }
        },
        {
          "from" : {
            "rawValue" : "A"
          },
          "to" : {
            "rawValue" : "C"
          }
        }
      ]
    }
    """)
}

@Test
func graphMermaid_Golden() throws {
    let compiled = try compileTinyGraph()
    let description = compiled.graphDescription()
    let mermaid = HiveGraphMermaidExporter.export(description)

    #expect(mermaid == """
    flowchart LR
      node_0[\"A\"]
      node_1[\"B\"]
      node_2[\"C\"]
      node_3[\"J\"]
      classDef router fill:#fff7ed,stroke:#c2410c,stroke-width:1px;
      class node_0 router
      node_0 --> node_1
      node_0 --> node_2
      classDef join fill:#eff6ff,stroke:#1d4ed8,stroke-width:1px;
      join_1{\"join:B+C:J\"}
      class join_1 join
      node_1 --> join_1
      node_2 --> join_1
      join_1 --> node_3
    """)
}

@Test
func graphDescription_DeterministicAcrossRecompiles() throws {
    let a = try compileTinyGraph().graphDescription()
    let b = try compileTinyGraph().graphDescription()
    #expect(a == b)
    #expect(HiveGraphMermaidExporter.export(a) == HiveGraphMermaidExporter.export(b))
}
