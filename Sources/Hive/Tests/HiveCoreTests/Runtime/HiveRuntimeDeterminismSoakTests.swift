import Foundation
import Testing
@testable import HiveCore

private struct DeterminismNoopClock: HiveClock {
    func nowNanoseconds() -> UInt64 { 0 }
    func sleep(nanoseconds: UInt64) async throws { try await Task.sleep(nanoseconds: nanoseconds) }
}

private struct DeterminismNoopLogger: HiveLogger {
    func debug(_ message: String, metadata: [String: String]) {}
    func info(_ message: String, metadata: [String: String]) {}
    func error(_ message: String, metadata: [String: String]) {}
}

private actor DeterminismCheckpointStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {
    private var checkpoints: [HiveCheckpoint<Schema>] = []

    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        checkpoints.append(checkpoint)
    }

    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints
            .filter { $0.threadID == threadID }
            .max { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.stepIndex < rhs.stepIndex
            }
    }

    func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] {
        let summaries = checkpoints
            .filter { $0.threadID == threadID }
            .sorted { lhs, rhs in
                if lhs.stepIndex == rhs.stepIndex {
                    return lhs.id.rawValue < rhs.id.rawValue
                }
                return lhs.stepIndex > rhs.stepIndex
            }
            .map {
                HiveCheckpointSummary(
                    id: $0.id,
                    threadID: $0.threadID,
                    runID: $0.runID,
                    stepIndex: $0.stepIndex,
                    schemaVersion: $0.schemaVersion,
                    graphVersion: $0.graphVersion
                )
            }

        guard let limit else { return summaries }
        return Array(summaries.prefix(max(0, limit)))
    }

    func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<Schema>? {
        checkpoints.first { $0.threadID == threadID && $0.id == id }
    }
}

private func makeDeterminismEnvironment<Schema: HiveSchema>(
    context: Schema.Context,
    checkpointStore: AnyHiveCheckpointStore<Schema>? = nil
) -> HiveEnvironment<Schema> {
    HiveEnvironment(
        context: context,
        clock: DeterminismNoopClock(),
        logger: DeterminismNoopLogger(),
        checkpointStore: checkpointStore
    )
}

private func collectDeterminismEvents(
    _ stream: AsyncThrowingStream<HiveEvent, Error>
) async -> [HiveEvent] {
    var events: [HiveEvent] = []
    do {
        for try await event in stream { events.append(event) }
    } catch {
        return events
    }
    return events
}

@Test("Determinism soak: seeded interrupt/resume + external writes + cancellation produce stable hashes")
func determinismSoakSeededSwarmWorkloadProducesStableHashes() async throws {
    enum Schema: HiveSchema {
        typealias InterruptPayload = String
        typealias ResumePayload = String

        static var channelSpecs: [AnyHiveChannelSpec<Schema>] {
            let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
            let notesKey = HiveChannelKey<Schema, [String]>(HiveChannelID("notes"))

            let valueSpec = HiveChannelSpec(
                key: valueKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { 0 },
                codec: HiveAnyCodec(IntCodec(id: "int")),
                persistence: .checkpointed
            )
            let notesSpec = HiveChannelSpec(
                key: notesKey,
                scope: .global,
                reducer: HiveReducer { current, update in current + update },
                updatePolicy: .multi,
                initial: { [] },
                codec: HiveAnyCodec(StringArrayCodec(id: "string-array")),
                persistence: .checkpointed
            )
            return [AnyHiveChannelSpec(valueSpec), AnyHiveChannelSpec(notesSpec)]
        }
    }

    let valueKey = HiveChannelKey<Schema, Int>(HiveChannelID("value"))
    let notesKey = HiveChannelKey<Schema, [String]>(HiveChannelID("notes"))

    var builder = HiveGraphBuilder<Schema>(start: [HiveNodeID("A")])
    builder.addNode(HiveNodeID("A")) { _ in
        HiveNodeOutput(
            writes: [AnyHiveWrite(valueKey, 1), AnyHiveWrite(notesKey, ["A"])],
            next: .useGraphEdges,
            interrupt: HiveInterruptRequest(payload: "pause")
        )
    }
    builder.addNode(HiveNodeID("B")) { input in
        let resumeValue = input.run.resume?.payload ?? "none"
        return HiveNodeOutput(
            writes: [AnyHiveWrite(notesKey, ["B:\(resumeValue)"])],
            next: .end
        )
    }
    builder.addEdge(from: HiveNodeID("A"), to: HiveNodeID("B"))

    let graph = try builder.compile()
    let trialCount = 10

    var transcriptHashes: [String] = []
    var stateHashes: [String] = []
    var baselineTranscript: HiveEventTranscript?

    for trial in 0..<trialCount {
        let checkpointStore = DeterminismCheckpointStore<Schema>()
        let runtime = try HiveRuntime(
            graph: graph,
            environment: makeDeterminismEnvironment(
                context: (),
                checkpointStore: AnyHiveCheckpointStore(checkpointStore)
            )
        )

        let threadID = HiveThreadID("determinism-main")

        let first = await runtime.run(
            threadID: threadID,
            input: (),
            options: HiveRunOptions(checkpointPolicy: .onInterrupt)
        )
        let firstEventsTask = Task { await collectDeterminismEvents(first.events) }
        let firstOutcome = try await first.outcome.value
        let firstEvents = await firstEventsTask.value

        guard case let .interrupted(interruption) = firstOutcome else {
            Issue.record("Expected interrupted outcome in trial \(trial)")
            return
        }

        let resumed = await runtime.resume(
            threadID: threadID,
            interruptID: interruption.interrupt.id,
            payload: "approved",
            options: HiveRunOptions(checkpointPolicy: .everyStep)
        )
        let resumedEventsTask = Task { await collectDeterminismEvents(resumed.events) }
        let resumedOutcome = try await resumed.outcome.value
        let resumedEvents = await resumedEventsTask.value
        guard case .finished = resumedOutcome else {
            Issue.record("Expected resumed run to finish in trial \(trial)")
            return
        }

        let external = await runtime.applyExternalWrites(
            threadID: threadID,
            writes: [AnyHiveWrite(valueKey, 5), AnyHiveWrite(notesKey, ["external"])],
            options: HiveRunOptions(checkpointPolicy: .everyStep)
        )
        let externalEventsTask = Task { await collectDeterminismEvents(external.events) }
        let externalOutcome = try await external.outcome.value
        let externalEvents = await externalEventsTask.value
        guard case .finished = externalOutcome else {
            Issue.record("Expected external writes to finish in trial \(trial)")
            return
        }

        let cancelRun = await runtime.run(
            threadID: HiveThreadID("determinism-cancel"),
            input: (),
            options: HiveRunOptions(checkpointPolicy: .everyStep)
        )
        cancelRun.outcome.cancel()
        let cancelEventsTask = Task { await collectDeterminismEvents(cancelRun.events) }
        let cancelOutcome = try await cancelRun.outcome.value
        let cancelEvents = await cancelEventsTask.value
        guard case .cancelled = cancelOutcome else {
            Issue.record("Expected cancellation outcome in trial \(trial)")
            return
        }

        let trialEvents = firstEvents + resumedEvents + externalEvents + cancelEvents
        let transcript = HiveEventTranscript(events: trialEvents)
        let transcriptHash = try transcript.transcriptHash()
        transcriptHashes.append(transcriptHash)

        let state = try #require(try await runtime.getState(threadID: threadID))
        let stateHash = HiveTranscriptHasher.finalStateHash(stateSnapshot: state)
        stateHashes.append(stateHash)

        if let baselineTranscript {
            if transcriptHash != transcriptHashes[0] {
                if let diff = baselineTranscript.firstDiff(comparedTo: transcript) {
                    Issue.record(
                        "Determinism divergence at trial \(trial): event \(diff.eventIndex), \(diff.keyPath), lhs=\(diff.lhs), rhs=\(diff.rhs)"
                    )
                } else {
                    Issue.record("Determinism divergence at trial \(trial) with no structured diff")
                }
                #expect(Bool(false))
                return
            }
        } else {
            baselineTranscript = transcript
        }
    }

    #expect(Set(transcriptHashes).count == 1)
    #expect(Set(stateHashes).count == 1)
    if let transcriptHash = transcriptHashes.first, let stateHash = stateHashes.first {
        print("determinism.transcriptHash=\(transcriptHash)")
        print("determinism.stateHash=\(stateHash)")
    }
}

private struct IntCodec: HiveCodec {
    let id: String

    func encode(_ value: Int) throws -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    func decode(_ data: Data) throws -> Int {
        guard data.count == MemoryLayout<Int>.size else { return 0 }
        return data.withUnsafeBytes { $0.load(as: Int.self) }.bigEndian
    }
}

private struct StringArrayCodec: HiveCodec {
    let id: String

    func encode(_ value: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func decode(_ data: Data) throws -> [String] {
        let decoder = JSONDecoder()
        return try decoder.decode([String].self, from: data)
    }
}
