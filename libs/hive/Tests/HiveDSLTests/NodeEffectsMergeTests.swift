import Testing
import HiveDSL

@Test("Effects appends writes in order")
func effectsAppendsWritesInOrder() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let key = HiveChannelKey<Schema, [Int]>(HiveChannelID("items"))

    let output: HiveNodeOutput<Schema> = Effects {
        Append(key, elements: [1, 2])
        Append(key, elements: [3])
        End()
    }

    #expect(output.writes.count == 2)
    #expect(output.writes[0].channelID == key.id)
    #expect(output.writes[1].channelID == key.id)
    #expect(output.writes[0].value as? [Int] == [1, 2])
    #expect(output.writes[1].value as? [Int] == [3])
}

@Test("Effects last-write-wins next")
func effectsLastWriteWinsNext() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let output: HiveNodeOutput<Schema> = Effects {
        GoTo("X")
        GoTo("Y")
    }

    #expect(output.next == .nodes([HiveNodeID("Y")]))
}

@Test("Effects last-write-wins interrupt")
func effectsLastWriteWinsInterrupt() throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let output: HiveNodeOutput<Schema> = Effects {
        Interrupt("a")
        Interrupt("b")
    }

    #expect(output.interrupt?.payload == "b")
}

@Test("SpawnEach produces stable task seeds order")
func spawnEachProducesStableOrder() throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] { [] }
    }

    let output: HiveNodeOutput<Schema> = Effects {
        SpawnEach([1, 2, 3], node: "Worker") { _ in
            HiveTaskLocalStore<Schema>.empty
        }
        End()
    }

    #expect(output.spawn.map(\.nodeID) == [HiveNodeID("Worker"), HiveNodeID("Worker"), HiveNodeID("Worker")])
}

