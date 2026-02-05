import Foundation
import Testing
import HiveRAGWax
import Wax

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

@Test("WaxRecall writes snippets to channel deterministically")
func waxRecallWritesSnippetsDeterministically() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-wax-\(UUID().uuidString)")

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.rag.searchMode = .textOnly
    config.rag.searchTopK = 8
    config.rag.maxSnippets = 8

    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
    defer {
        Task { try? await memory.close() }
    }

    try await memory.remember("Alpha is the first letter.")
    try await memory.remember("Beta is the second letter.")
    try await memory.flush()

    struct Ctx: Sendable { let memory: MemoryOrchestrator }

    enum Schema: HiveSchema {
        typealias Context = Ctx
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, [HiveRAGSnippet]>(HiveChannelID("snippets"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { [] },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let snippetsKey = HiveChannelKey<Schema, [HiveRAGSnippet]>(HiveChannelID("snippets"))

    let workflow = Workflow<Schema> {
        WaxRecall(
            "recall",
            memory: \.memory,
            query: "Alpha",
            writeSnippetsTo: snippetsKey
        )
        .start()
    }

    let graph = try workflow.compile()
    let env = HiveEnvironment<Schema>(
        context: Ctx(memory: memory),
        clock: NoopClock(),
        logger: NoopLogger()
    )

    let runtime = HiveRuntime(graph: graph, environment: env)

    let thread1 = HiveThreadID("wax-1")
    _ = try await (await runtime.run(threadID: thread1, input: (), options: HiveRunOptions())).outcome.value
    guard let store1 = await runtime.getLatestStore(threadID: thread1) else {
        #expect(Bool(false))
        return
    }
    let snippets1 = try store1.get(snippetsKey)
    #expect(!snippets1.isEmpty)
    #expect(snippets1.contains { $0.text.localizedCaseInsensitiveContains("alpha") })

    let thread2 = HiveThreadID("wax-2")
    _ = try await (await runtime.run(threadID: thread2, input: (), options: HiveRunOptions())).outcome.value
    guard let store2 = await runtime.getLatestStore(threadID: thread2) else {
        #expect(Bool(false))
        return
    }
    let snippets2 = try store2.get(snippetsKey)
    #expect(snippets2 == snippets1)
}

@Test("WaxRecall works without vector search embedder (text-only mode)")
func waxRecallWorksInTextOnlyMode() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-wax-\(UUID().uuidString)")

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.rag.searchMode = .textOnly

    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
    defer {
        Task { try? await memory.close() }
    }

    try await memory.remember("Text-only memory.")
    try await memory.flush()

    let ctx = try await memory.recall(query: "Text")
    #expect(!ctx.items.isEmpty)
}

