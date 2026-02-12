import Foundation
import HiveCore

private enum ExampleSchema: HiveSchema {
    typealias InterruptPayload = String
    typealias ResumePayload = String

    static var channelSpecs: [AnyHiveChannelSpec<ExampleSchema>] {
        let stringCodec = HiveAnyCodec(StringCodec())
        let stringArrayCodec = HiveAnyCodec(StringArrayCodec())
        let resultsSpec = HiveChannelSpec(
            key: ExampleChannels.results,
            scope: .global,
            reducer: HiveReducer.append(),
            updatePolicy: .multi,
            initial: { [] },
            codec: stringArrayCodec,
            persistence: .checkpointed
        )
        let itemSpec = HiveChannelSpec(
            key: ExampleChannels.item,
            scope: .taskLocal,
            reducer: HiveReducer.lastWriteWins(),
            updatePolicy: .single,
            initial: { "" },
            codec: stringCodec,
            persistence: .checkpointed
        )
        return [AnyHiveChannelSpec(resultsSpec), AnyHiveChannelSpec(itemSpec)]
    }
}

private struct StringCodec: HiveCodec {
    let id: String = "string.v1"

    func encode(_ value: String) throws -> Data {
        Data(value.utf8)
    }

    func decode(_ data: Data) throws -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private struct StringArrayCodec: HiveCodec {
    let id: String = "string-array.v1"

    func encode(_ value: [String]) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func decode(_ data: Data) throws -> [String] {
        try JSONDecoder().decode([String].self, from: data)
    }
}

private enum ExampleChannels {
    static let results = HiveChannelKey<ExampleSchema, [String]>(HiveChannelID("results"))
    static let item = HiveChannelKey<ExampleSchema, String>(HiveChannelID("item"))
}

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor InMemoryCheckpointStore<Schema: HiveSchema>: HiveCheckpointStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex { return lhs.id.rawValue < rhs.id.rawValue }
                return lhs.stepIndex < rhs.stepIndex
            }
    }
}

@main
struct TinyGraphExample {
    static func main() async {
        do {
            try await run()
        } catch {
            print("Example failed: \(error)")
        }
    }

    private static func run() async throws {
        let checkpointStore = InMemoryCheckpointStore<ExampleSchema>()
        let environment = HiveEnvironment(
            context: (),
            clock: NoopClock(),
            logger: NoopLogger(),
            checkpointStore: AnyHiveCheckpointStore(checkpointStore)
        )

        let graph = try makeGraph()
        let runtime = try HiveRuntime(graph: graph, environment: environment)
        let threadID = HiveThreadID("example-thread")

        print("Starting run...")
        let initial = await runtime.run(
            threadID: threadID,
            input: (),
            options: HiveRunOptions(checkpointPolicy: .onInterrupt)
        )

        let initialOutcome = try await initial.outcome.value
        guard case let .interrupted(interruption) = initialOutcome else {
            print("Expected interrupt, got: \(initialOutcome)")
            return
        }

        print("Interrupted with payload: \(interruption.interrupt.payload)")
        print("Resuming...")

        let resumed = await runtime.resume(
            threadID: threadID,
            interruptID: interruption.interrupt.id,
            payload: "approved",
            options: HiveRunOptions(checkpointPolicy: .onInterrupt)
        )

        let resumedOutcome = try await resumed.outcome.value
        guard case let .finished(output, _) = resumedOutcome else {
            print("Expected finished, got: \(resumedOutcome)")
            return
        }

        if case let .fullStore(store) = output {
            let results = try store.get(ExampleChannels.results)
            print("Final results: \(results)")
        }
    }

    private static func makeGraph() throws -> CompiledHiveGraph<ExampleSchema> {
        let start = HiveNodeID("Start")
        let workerA = HiveNodeID("WorkerA")
        let workerB = HiveNodeID("WorkerB")
        let gate = HiveNodeID("Gate")
        let finalize = HiveNodeID("Finalize")

        var builder = HiveGraphBuilder<ExampleSchema>(start: [start])

        builder.addNode(start) { _ in
            let apple = try makeTaskLocal(item: "apple")
            let banana = try makeTaskLocal(item: "banana")
            return HiveNodeOutput(
                spawn: [
                    HiveTaskSeed(nodeID: workerA, local: apple),
                    HiveTaskSeed(nodeID: workerB, local: banana)
                ],
                next: .end
            )
        }

        builder.addNode(workerA) { input in
            let item = try input.store.get(ExampleChannels.item)
            let message = "WorkerA processed \(item)"
            return HiveNodeOutput(
                writes: [AnyHiveWrite(ExampleChannels.results, [message])],
                next: .end
            )
        }

        builder.addNode(workerB) { input in
            let item = try input.store.get(ExampleChannels.item)
            let message = "WorkerB processed \(item)"
            return HiveNodeOutput(
                writes: [AnyHiveWrite(ExampleChannels.results, [message])],
                next: .end
            )
        }

        builder.addNode(gate) { input in
            let results = try input.store.get(ExampleChannels.results)
            print("Gate sees results: \(results)")
            return HiveNodeOutput(
                next: .useGraphEdges,
                interrupt: HiveInterruptRequest(payload: "review")
            )
        }

        builder.addNode(finalize) { input in
            if let resume = input.run.resume {
                print("Finalize resume payload: \(resume.payload)")
            }
            let results = try input.store.get(ExampleChannels.results)
            print("Finalize results: \(results)")
            return HiveNodeOutput(next: .end)
        }

        builder.addJoinEdge(parents: [workerA, workerB], target: gate)
        builder.addEdge(from: gate, to: finalize)

        return try builder.compile()
    }

    private static func makeTaskLocal(item: String) throws -> HiveTaskLocalStore<ExampleSchema> {
        var local = HiveTaskLocalStore<ExampleSchema>.empty
        try local.set(ExampleChannels.item, item)
        return local
    }
}
