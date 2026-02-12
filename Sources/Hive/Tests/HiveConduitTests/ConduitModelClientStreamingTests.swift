import Foundation
import Testing
import HiveConduit
import Conduit

private struct StubModelID: ModelIdentifying {
    let rawValue: String

    var displayName: String { rawValue }
    var provider: ProviderType { .openAI }
    var description: String { rawValue }
}

private enum StubError: Error, Sendable {
    case boom
}

private struct StubTextGenerator: TextGenerator, Sendable {
    typealias ModelID = StubModelID

    let result: GenerationResult
    let streamChunks: [GenerationChunk]
    let streamError: StubError?
    let keepStreamOpenAfterChunks: Bool

    init(
        result: GenerationResult,
        streamChunks: [GenerationChunk],
        streamError: StubError?,
        keepStreamOpenAfterChunks: Bool = false
    ) {
        self.result = result
        self.streamChunks = streamChunks
        self.streamError = streamError
        self.keepStreamOpenAfterChunks = keepStreamOpenAfterChunks
    }

    func generate(
        _ prompt: String,
        model: ModelID,
        config: GenerateConfig
    ) async throws -> String {
        result.text
    }

    func generate(
        messages: [Message],
        model: ModelID,
        config: GenerateConfig
    ) async throws -> GenerationResult {
        result
    }

    func stream(
        _ prompt: String,
        model: ModelID,
        config: GenerateConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for chunk in streamChunks where !chunk.text.isEmpty {
                    continuation.yield(chunk.text)
                }
                if let error = streamError {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
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
                if let error = streamError {
                    continuation.finish(throwing: error)
                } else if keepStreamOpenAfterChunks {
                    // Intentionally keep the stream open for completion-path resilience tests.
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

private func collectChunks(
    _ stream: AsyncThrowingStream<HiveChatStreamChunk, Error>
) async throws -> [HiveChatStreamChunk] {
    var chunks: [HiveChatStreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

private func collectChunksAndError(
    _ stream: AsyncThrowingStream<HiveChatStreamChunk, Error>
) async -> ([HiveChatStreamChunk], Error?) {
    var chunks: [HiveChatStreamChunk] = []
    do {
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return (chunks, nil)
    } catch {
        return (chunks, error)
    }
}

private actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        guard isSignaled == false else { return }
        isSignaled = true
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        if isSignaled {
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    if isSignaled {
                        continuation.resume()
                        return
                    }
                    continuations[waiterID] = continuation
                }
            },
            onCancel: {
                Task {
                    await self.cancelWaiter(waiterID)
                }
            }
        )
    }

    private func cancelWaiter(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume()
    }

    func value() -> Bool {
        isSignaled
    }
}

private func waitForSignal(
    _ signal: AsyncSignal,
    maxYields: Int
) async -> Bool {
    for _ in 0..<max(1, maxYields) {
        if await signal.value() {
            return true
        }
        await Task.yield()
    }
    return await signal.value()
}

@Test("ConduitModelClient stream emits tokens then final chunk")
func conduitModelClientStreamEmitsFinalChunk() async throws {
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
    let provider = StubTextGenerator(
        result: result,
        streamChunks: streamChunks,
        streamError: nil
    )
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.boom }
            return modelID
        },
        messageID: { "msg-final" }
    )
    let request = HiveChatRequest(
        model: modelID.rawValue,
        messages: [HiveChatMessage(id: "msg-1", role: .user, content: "hi")],
        tools: []
    )

    let chunks = try await collectChunks(client.stream(request))
    let tokens = chunks.compactMap { chunk -> String? in
        if case let .token(token) = chunk { return token }
        return nil
    }
    let finals = chunks.compactMap { chunk -> HiveChatResponse? in
        if case let .final(response) = chunk { return response }
        return nil
    }

    #expect(!tokens.isEmpty)
    #expect(tokens.joined() == "Hello")
    #expect(finals.count == 1)
    #expect({
        guard let last = chunks.last else { return false }
        if case .final = last { return true }
        return false
    }())
    #expect(finals.first?.message.content == "Hello")
}

@Test("ConduitModelClient stream propagates errors without final chunk")
func conduitModelClientStreamPropagatesErrorWithoutFinalChunk() async {
    let streamChunks: [GenerationChunk] = [
        GenerationChunk(text: "Hi")
    ]
    let result = GenerationResult(
        text: "Hi",
        tokenCount: 1,
        generationTime: 0,
        tokensPerSecond: 0,
        finishReason: .stop
    )
    let provider = StubTextGenerator(
        result: result,
        streamChunks: streamChunks,
        streamError: .boom
    )
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.boom }
            return modelID
        },
        messageID: { "msg-error" }
    )
    let request = HiveChatRequest(
        model: modelID.rawValue,
        messages: [HiveChatMessage(id: "msg-2", role: .user, content: "hi")],
        tools: []
    )

    let (chunks, error) = await collectChunksAndError(client.stream(request))
    let tokens = chunks.compactMap { chunk -> String? in
        if case let .token(token) = chunk { return token }
        return nil
    }
    let finals = chunks.compactMap { chunk -> HiveChatResponse? in
        if case let .final(response) = chunk { return response }
        return nil
    }

    #expect(error != nil)
    #expect(tokens.joined() == "Hi")
    #expect(finals.isEmpty)
}

@Test("ConduitModelClient stream rejects completion without final chunk")
func conduitModelClientStreamRejectsMissingFinalChunk() async {
    let streamChunks: [GenerationChunk] = [
        GenerationChunk(text: "Hi")
    ]
    let result = GenerationResult(
        text: "Hi",
        tokenCount: 1,
        generationTime: 0,
        tokensPerSecond: 0,
        finishReason: .stop
    )
    let provider = StubTextGenerator(
        result: result,
        streamChunks: streamChunks,
        streamError: nil
    )
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.boom }
            return modelID
        },
        messageID: { "msg-missing-final" }
    )
    let request = HiveChatRequest(
        model: modelID.rawValue,
        messages: [HiveChatMessage(id: "msg-4", role: .user, content: "hi")],
        tools: []
    )

    let (chunks, error) = await collectChunksAndError(client.stream(request))
    let tokens = chunks.compactMap { chunk -> String? in
        if case let .token(token) = chunk { return token }
        return nil
    }
    let finals = chunks.compactMap { chunk -> HiveChatResponse? in
        if case let .final(response) = chunk { return response }
        return nil
    }

    if case let .modelStreamInvalid(reason) = error as? HiveRuntimeError {
        #expect(!reason.isEmpty)
    } else {
        #expect(Bool(false))
    }
    #expect(tokens.joined() == "Hi")
    #expect(finals.isEmpty)
}

@Test("ConduitModelClient emits final even if provider stream remains open")
func conduitModelClientStreamFinalizesWithoutUpstreamFinish() async throws {
    let streamChunks: [GenerationChunk] = [
        GenerationChunk(text: "Hi"),
        GenerationChunk.completion(finishReason: .stop)
    ]
    let result = GenerationResult(
        text: "Hi",
        tokenCount: 1,
        generationTime: 0,
        tokensPerSecond: 0,
        finishReason: .stop
    )
    let provider = StubTextGenerator(
        result: result,
        streamChunks: streamChunks,
        streamError: nil,
        keepStreamOpenAfterChunks: true
    )
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.boom }
            return modelID
        },
        messageID: { "msg-open-stream" }
    )
    let request = HiveChatRequest(
        model: modelID.rawValue,
        messages: [HiveChatMessage(id: "msg-open", role: .user, content: "hi")],
        tools: []
    )

    let finalSeen = AsyncSignal()
    let consume = Task {
        for try await chunk in client.stream(request) {
            if case .final = chunk {
                await finalSeen.signal()
                return
            }
        }
    }

    let observedFinal = await waitForSignal(finalSeen, maxYields: 50_000)
    consume.cancel()
    _ = await consume.result

    #expect(observedFinal)
}

@Test("ConduitModelClient ignores chunks after final completion")
func conduitModelClientStreamIgnoresExtraChunksAfterFinal() async {
    let streamChunks: [GenerationChunk] = [
        GenerationChunk(text: "Hi"),
        GenerationChunk.completion(finishReason: .stop),
        GenerationChunk(text: "late")
    ]
    let result = GenerationResult(
        text: "Hi",
        tokenCount: 1,
        generationTime: 0,
        tokensPerSecond: 0,
        finishReason: .stop
    )
    let provider = StubTextGenerator(
        result: result,
        streamChunks: streamChunks,
        streamError: nil
    )
    let modelID = StubModelID(rawValue: "stub-model")
    let client = ConduitModelClient(
        provider: provider,
        modelIDForName: { name in
            guard name == modelID.rawValue else { throw StubError.boom }
            return modelID
        },
        messageID: { "msg-extra" }
    )
    let request = HiveChatRequest(
        model: modelID.rawValue,
        messages: [HiveChatMessage(id: "msg-3", role: .user, content: "hi")],
        tools: []
    )

    let (chunks, error) = await collectChunksAndError(client.stream(request))
    let finals = chunks.compactMap { chunk -> HiveChatResponse? in
        if case let .final(response) = chunk { return response }
        return nil
    }

    #expect(error == nil)
    #expect(finals.count == 1)
    #expect(finals.first?.message.content == "Hi")
}
