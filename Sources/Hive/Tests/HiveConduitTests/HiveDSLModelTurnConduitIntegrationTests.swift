import Testing
import HiveConduit
import HiveDSL
import Conduit

private struct NoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct NoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private struct StubModelID: ModelIdentifying {
    let rawValue: String

    var displayName: String { rawValue }
    var provider: ProviderType { .openAI }
    var description: String { rawValue }
}

private struct StubTextGenerator: TextGenerator, Sendable {
    typealias ModelID = StubModelID

    let result: GenerationResult
    let streamChunks: [GenerationChunk]

    func generate(_ prompt: String, model: ModelID, config: GenerateConfig) async throws -> String {
        result.text
    }

    func generate(messages: [Message], model: ModelID, config: GenerateConfig) async throws -> GenerationResult {
        result
    }

    func stream(_ prompt: String, model: ModelID, config: GenerateConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for chunk in streamChunks where !chunk.text.isEmpty {
                    continuation.yield(chunk.text)
                }
                continuation.finish()
            }
        }
    }

    func streamWithMetadata(
        messages: [Message],
        model: ModelID,
        config: GenerateConfig
    ) -> AsyncThrowingStream<GenerationChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for chunk in streamChunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }
}

private enum StubError: Error, Sendable {
    case unknownModelName
}

@Test("ModelTurn works with ConduitModelClient streaming/complete contract")
func modelTurnWorksWithConduitModelClient() async throws {
    enum Schema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let key = HiveChannelKey<Schema, String>(HiveChannelID("out"))
            let spec = HiveChannelSpec(
                key: key,
                scope: .global,
                reducer: .lastWriteWins(),
                updatePolicy: .single,
                initial: { "" },
                persistence: .untracked
            )
            return [AnyHiveChannelSpec(spec)]
        }
    }

    let outKey = HiveChannelKey<Schema, String>(HiveChannelID("out"))

    let streamChunks: [GenerationChunk] = [
        GenerationChunk(text: "Hel"),
        GenerationChunk(text: "lo"),
        GenerationChunk.completion(finishReason: .stop)
    ]
    let result = GenerationResult(
        text: "Hello",
        tokenCount: 2,
        generationTime: 0,
        tokensPerSecond: 0,
        finishReason: .stop
    )
    let provider = StubTextGenerator(result: result, streamChunks: streamChunks)
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.unknownModelName }
            return modelID
        },
        messageID: { "msg-final" }
    )

    let workflow = Workflow<Schema> {
        ModelTurn(
            "mt",
            model: modelID.rawValue,
            messages: [HiveChatMessage(id: "msg-1", role: .user, content: "hi")]
        )
        .writes(to: outKey)
        .start()
    }

    let graph = try workflow.compile()
    let env = HiveEnvironment<Schema>(
        context: (),
        clock: NoopClock(),
        logger: NoopLogger(),
        model: AnyHiveModelClient(client)
    )

    let runtime = HiveRuntime(graph: graph, environment: env)
    let threadID = HiveThreadID("mt-conduit")
    let handle = await runtime.run(threadID: threadID, input: (), options: HiveRunOptions())
    _ = try await handle.outcome.value

    guard let store = await runtime.getLatestStore(threadID: threadID) else {
        #expect(Bool(false))
        return
    }

    #expect(try store.get(outKey) == "Hello")
}
