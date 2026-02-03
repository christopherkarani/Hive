import Foundation
import HiveCore
import Wax

private enum HiveCheckpointWaxMetadataKey {
    static let threadID = "hive.threadID"
    static let stepIndex = "hive.stepIndex"
    static let checkpointID = "hive.checkpointID"
    static let runID = "hive.runID"
    static let schemaVersion = "hive.schemaVersion"
    static let graphVersion = "hive.graphVersion"
}

/// Wax-backed checkpoint store implementation.
public actor HiveCheckpointWaxStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {

    private static var checkpointKind: String { "hive.checkpoint" }

    private let wax: Wax
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(wax: Wax) {
        self.wax = wax
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public static func create(
        at url: URL,
        walSize: UInt64 = Constants.defaultWalSize,
        options: WaxOptions = .init()
    ) async throws -> HiveCheckpointWaxStore<Schema> {
        let wax = try await Wax.create(at: url, walSize: walSize, options: options)
        return HiveCheckpointWaxStore(wax: wax)
    }

    public static func open(
        at url: URL,
        options: WaxOptions = .init()
    ) async throws -> HiveCheckpointWaxStore<Schema> {
        let wax = try await Wax.open(at: url, options: options)
        return HiveCheckpointWaxStore(wax: wax)
    }

    public func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        let data = try encoder.encode(checkpoint)
        let metadata = Metadata([
            HiveCheckpointWaxMetadataKey.threadID: checkpoint.threadID.rawValue,
            HiveCheckpointWaxMetadataKey.stepIndex: String(checkpoint.stepIndex),
            HiveCheckpointWaxMetadataKey.checkpointID: checkpoint.id.rawValue,
            HiveCheckpointWaxMetadataKey.runID: checkpoint.runID.rawValue.uuidString.lowercased(),
            HiveCheckpointWaxMetadataKey.schemaVersion: checkpoint.schemaVersion,
            HiveCheckpointWaxMetadataKey.graphVersion: checkpoint.graphVersion,
        ])
        let options = FrameMetaSubset(
            kind: "hive.checkpoint",
            metadata: metadata
        )
        _ = try await wax.put(data, options: options, compression: .plain)
        try await wax.commit()
    }

    public func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        let metas = await wax.frameMetas()

        var best: (frameId: UInt64, stepIndex: Int)?
        for meta in metas {
            guard meta.kind == Self.checkpointKind else { continue }
            guard let metadata = meta.metadata?.entries else { continue }
            guard metadata[HiveCheckpointWaxMetadataKey.threadID] == threadID.rawValue else { continue }
            guard let stepString = metadata[HiveCheckpointWaxMetadataKey.stepIndex],
                  let stepIndex = Int(stepString) else { continue }

            if let current = best {
                if stepIndex > current.stepIndex {
                    best = (meta.id, stepIndex)
                } else if stepIndex == current.stepIndex, meta.id > current.frameId {
                    best = (meta.id, stepIndex)
                }
            } else {
                best = (meta.id, stepIndex)
            }
        }

        guard let best else { return nil }
        let payload = try await wax.frameContent(frameId: best.frameId)
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }

    public func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] {
        let metas = await wax.frameMetas()
        var results: [(summary: HiveCheckpointSummary, frameID: UInt64)] = []
        results.reserveCapacity(metas.count)

        for meta in metas {
            guard meta.kind == Self.checkpointKind else { continue }
            guard let metadata = meta.metadata?.entries else { continue }
            guard metadata[HiveCheckpointWaxMetadataKey.threadID] == threadID.rawValue else { continue }

            guard let checkpointIDRaw = metadata[HiveCheckpointWaxMetadataKey.checkpointID] else { continue }
            guard let runIDString = metadata[HiveCheckpointWaxMetadataKey.runID],
                  let runUUID = UUID(uuidString: runIDString) else { continue }
            guard let stepString = metadata[HiveCheckpointWaxMetadataKey.stepIndex],
                  let stepIndex = Int(stepString) else { continue }

            let summary = HiveCheckpointSummary(
                id: HiveCheckpointID(checkpointIDRaw),
                threadID: threadID,
                runID: HiveRunID(runUUID),
                stepIndex: stepIndex,
                schemaVersion: metadata[HiveCheckpointWaxMetadataKey.schemaVersion],
                graphVersion: metadata[HiveCheckpointWaxMetadataKey.graphVersion],
                createdAt: nil,
                backendID: String(meta.id)
            )
            results.append((summary: summary, frameID: meta.id))
        }

        results.sort { lhs, rhs in
            if lhs.summary.stepIndex != rhs.summary.stepIndex {
                return lhs.summary.stepIndex > rhs.summary.stepIndex
            }
            return lhs.frameID > rhs.frameID
        }

        if let limit, limit <= 0 {
            return []
        }
        let summaries = results.map(\.summary)
        if let limit {
            return Array(summaries.prefix(limit))
        }
        return summaries
    }

    public func loadCheckpoint(threadID: HiveThreadID, id: HiveCheckpointID) async throws -> HiveCheckpoint<Schema>? {
        let metas = await wax.frameMetas()
        var bestFrameID: UInt64?
        for meta in metas {
            guard meta.kind == Self.checkpointKind else { continue }
            guard let metadata = meta.metadata?.entries else { continue }
            guard metadata[HiveCheckpointWaxMetadataKey.threadID] == threadID.rawValue else { continue }
            guard metadata[HiveCheckpointWaxMetadataKey.checkpointID] == id.rawValue else { continue }

            if let current = bestFrameID {
                if meta.id > current {
                    bestFrameID = meta.id
                }
            } else {
                bestFrameID = meta.id
            }
        }

        guard let bestFrameID else { return nil }
        let payload = try await wax.frameContent(frameId: bestFrameID)
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }
}
