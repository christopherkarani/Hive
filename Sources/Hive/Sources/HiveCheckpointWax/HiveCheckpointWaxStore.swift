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

private actor HiveCheckpointWaxFrameStoreRegistry {
    static let shared = HiveCheckpointWaxFrameStoreRegistry()

    private var storesByPath: [String: FrameStore] = [:]

    func create(at url: URL, walSize: UInt64) async throws -> FrameStore {
        let key = url.standardizedFileURL.path
        if let existing = storesByPath[key] {
            return existing
        }

        let store: FrameStore
        if FileManager.default.fileExists(atPath: key) {
            store = try await FrameStore.open(at: url)
        } else {
            store = try await FrameStore.create(at: url, walSize: walSize)
        }
        storesByPath[key] = store
        return store
    }

    func open(at url: URL) async throws -> FrameStore {
        let key = url.standardizedFileURL.path
        if let existing = storesByPath[key] {
            return existing
        }

        let store = try await FrameStore.open(at: url)
        storesByPath[key] = store
        return store
    }
}

/// Wax-backed checkpoint store implementation.
public actor HiveCheckpointWaxStore<Schema: HiveSchema>: HiveCheckpointQueryableStore {

    private static var checkpointKind: String { "hive.checkpoint" }

    private let frames: FrameStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(frames: FrameStore) {
        self.frames = frames
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public static func create(
        at url: URL,
        walSize: UInt64 = FrameStore.defaultWalSize
    ) async throws -> HiveCheckpointWaxStore<Schema> {
        let frames = try await HiveCheckpointWaxFrameStoreRegistry.shared.create(at: url, walSize: walSize)
        return HiveCheckpointWaxStore(frames: frames)
    }

    public static func open(at url: URL) async throws -> HiveCheckpointWaxStore<Schema> {
        let frames = try await HiveCheckpointWaxFrameStoreRegistry.shared.open(at: url)
        return HiveCheckpointWaxStore(frames: frames)
    }

    public func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        let data = try encoder.encode(checkpoint)
        let metadata = [
            HiveCheckpointWaxMetadataKey.threadID: checkpoint.threadID.rawValue,
            HiveCheckpointWaxMetadataKey.stepIndex: String(checkpoint.stepIndex),
            HiveCheckpointWaxMetadataKey.checkpointID: checkpoint.id.rawValue,
            HiveCheckpointWaxMetadataKey.runID: checkpoint.runID.rawValue.uuidString.lowercased(),
            HiveCheckpointWaxMetadataKey.schemaVersion: checkpoint.schemaVersion,
            HiveCheckpointWaxMetadataKey.graphVersion: checkpoint.graphVersion,
        ]
        _ = try await frames.put(data, kind: Self.checkpointKind, metadata: metadata)
    }

    public func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        let metas = await frames.frames()

        var best: (frameID: UInt64, stepIndex: Int)?
        for meta in metas {
            guard isActiveCurrentFrame(meta) else { continue }
            let metadata = meta.metadata
            guard metadata[HiveCheckpointWaxMetadataKey.threadID] == threadID.rawValue else { continue }
            guard let stepString = metadata[HiveCheckpointWaxMetadataKey.stepIndex],
                  let stepIndex = Int(stepString) else { continue }

            if let current = best {
                if stepIndex > current.stepIndex {
                    best = (meta.id, stepIndex)
                } else if stepIndex == current.stepIndex, meta.id > current.frameID {
                    best = (meta.id, stepIndex)
                }
            } else {
                best = (meta.id, stepIndex)
            }
        }

        guard let best else { return nil }
        let payload = try await frames.content(frameID: best.frameID)
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }

    public func listCheckpoints(threadID: HiveThreadID, limit: Int?) async throws -> [HiveCheckpointSummary] {
        let metas = await frames.frames()
        var results: [(summary: HiveCheckpointSummary, frameID: UInt64)] = []
        results.reserveCapacity(metas.count)

        for meta in metas {
            guard isActiveCurrentFrame(meta) else { continue }
            let metadata = meta.metadata
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
        let metas = await frames.frames()
        var bestFrameID: UInt64?
        for meta in metas {
            guard isActiveCurrentFrame(meta) else { continue }
            let metadata = meta.metadata
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
        let payload = try await frames.content(frameID: bestFrameID)
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }

    private func isActiveCurrentFrame(_ meta: FrameStore.Frame) -> Bool {
        guard meta.kind == Self.checkpointKind else { return false }
        guard meta.status == .active else { return false }
        guard meta.supersededBy == nil else { return false }
        return true
    }

    func _deleteFrameForTesting(frameID: UInt64) async throws {
        try await frames.delete(frameID: frameID)
    }
}
