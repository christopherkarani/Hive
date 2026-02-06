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

private struct DeterministicEmbedder: EmbeddingProvider {
    let dimensions: Int = 3
    let normalize: Bool = false
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "tests",
        model: "deterministic",
        dimensions: 3,
        normalized: false
    )

    func embed(_ text: String) async throws -> [Float] {
        let seed = Float(text.unicodeScalars.reduce(0) { $0 + Int($1.value) % 19 })
        return [seed, seed + 1, seed + 2]
    }
}

private func makeTempMemoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-wax-\(UUID().uuidString)")
}

private func withMemoryOrchestrator<T>(
    at url: URL,
    config: OrchestratorConfig,
    embedder: (any EmbeddingProvider)? = nil,
    _ body: (MemoryOrchestrator) async throws -> T
) async throws -> T {
    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
    do {
        let result = try await body(memory)
        try await memory.close()
        return result
    } catch {
        try? await memory.close()
        throw error
    }
}

@Test("WaxRecall writes snippets to channel deterministically")
func waxRecallWritesSnippetsDeterministically() async throws {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.rag.searchMode = .textOnly
    config.rag.searchTopK = 8
    config.rag.maxSnippets = 8

    try await withMemoryOrchestrator(at: makeTempMemoryURL(), config: config, embedder: nil) { memory in
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
}

@Test("WaxRecall works without vector search embedder (text-only mode)")
func waxRecallWorksInTextOnlyMode() async throws {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.rag.searchMode = .textOnly

    try await withMemoryOrchestrator(at: makeTempMemoryURL(), config: config, embedder: nil) { memory in
        try await memory.remember("Text-only memory.")
        try await memory.flush()

        let ctx = try await memory.recall(query: "Text")
        #expect(!ctx.items.isEmpty)
    }
}

@Test("MemoryOrchestrator init fails when vector search enabled and embedder missing on a fresh store")
func memoryOrchestratorInitFailsForFreshStoreWithoutEmbedder() async throws {
    let url = makeTempMemoryURL()
    var config = OrchestratorConfig.default
    config.enableVectorSearch = true

    do {
        let memory = try await MemoryOrchestrator(at: url, config: config, embedder: nil)
        try await memory.close()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io(let details) = error else {
            #expect(Bool(false))
            return
        }
        #expect(details == "enableVectorSearch=true requires an EmbeddingProvider for ingest-time embeddings")
    } catch {
        #expect(Bool(false))
    }
}

@Test("MemoryOrchestrator.recall with .always fails when vector search is disabled")
func memoryOrchestratorRecallAlwaysFailsWhenVectorSearchDisabled() async throws {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.rag.searchMode = .textOnly

    try await withMemoryOrchestrator(at: makeTempMemoryURL(), config: config, embedder: nil) { memory in
        do {
            _ = try await memory.recall(query: "Text", embeddingPolicy: .always)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let details) = error else {
                #expect(Bool(false))
                return
            }
            #expect(details == "query embedding requested but vector search is disabled")
        } catch {
            #expect(Bool(false))
        }
    }
}

@Test("MemoryOrchestrator.recall with .always fails when vector search enabled but embedder missing")
func memoryOrchestratorRecallAlwaysFailsWhenEmbedderMissing() async throws {
    let url = makeTempMemoryURL()
    var config = OrchestratorConfig.default
    config.enableVectorSearch = true

    try await withMemoryOrchestrator(
        at: url,
        config: config,
        embedder: DeterministicEmbedder()
    ) { memory in
        try await memory.remember("Create vector index once.")
        try await memory.flush()
    }

    try await withMemoryOrchestrator(at: url, config: config, embedder: nil) { memory in
        do {
            _ = try await memory.recall(query: "Create", embeddingPolicy: .always)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let details) = error else {
                #expect(Bool(false))
                return
            }
            #expect(details == "query embedding requested but no EmbeddingProvider configured")
        } catch {
            #expect(Bool(false))
        }
    }
}
