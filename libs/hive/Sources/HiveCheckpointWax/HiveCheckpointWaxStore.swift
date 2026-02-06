import Foundation
import HiveCore
import Wax

private enum HiveCheckpointWaxMetadataKey {
    static let threadID = "hive.threadID"
    static let stepIndex = "hive.stepIndex"
    static let checkpointID = "hive.checkpointID"
    static let runID = "hive.runID"
}

/// Wax-backed checkpoint store implementation.
public actor HiveCheckpointWaxStore<Schema: HiveSchema>: HiveCheckpointStore {

    private static var checkpointKind: String { "hive.checkpoint" }

    private let wax: Wax
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var latestFrameIDByThreadID: [HiveThreadID: UInt64] = [:]
    private var hasScannedAllCheckpointFrames = false
    private var pendingFrameIDByThreadID: [HiveThreadID: UInt64] = [:]

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
        try await save(checkpoint, commit: true)
    }

    /// Saves a checkpoint and optionally commits it immediately.
    public func save(_ checkpoint: HiveCheckpoint<Schema>, commit: Bool) async throws {
        let data = try encoder.encode(checkpoint)
        let metadata = Metadata([
            HiveCheckpointWaxMetadataKey.threadID: checkpoint.threadID.rawValue,
            HiveCheckpointWaxMetadataKey.stepIndex: String(checkpoint.stepIndex),
            HiveCheckpointWaxMetadataKey.checkpointID: checkpoint.id.rawValue,
            HiveCheckpointWaxMetadataKey.runID: checkpoint.runID.rawValue.uuidString.lowercased()
        ])
        let options = FrameMetaSubset(
            kind: Self.checkpointKind,
            metadata: metadata
        )
        let frameID = try await wax.put(data, options: options, compression: .plain)
        updatePendingFrameIDCache(threadID: checkpoint.threadID, frameID: frameID)

        if commit {
            try await wax.commit()
            mergePendingFrameIDCacheIntoLatest()
        }
    }

    /// Commits staged writes to Wax.
    public func flush() async throws {
        try await wax.commit()
        mergePendingFrameIDCacheIntoLatest()
    }

    /// Closes the underlying Wax store.
    public func close() async throws {
        try await wax.close()
        latestFrameIDByThreadID.removeAll(keepingCapacity: false)
        pendingFrameIDByThreadID.removeAll(keepingCapacity: false)
        hasScannedAllCheckpointFrames = false
    }

    public func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        if let cached = newestKnownFrameID(for: threadID) {
            return try await loadCheckpoint(frameID: cached.frameID, includePending: cached.includePending)
        }

        if !hasScannedAllCheckpointFrames {
            await rebuildLatestFrameIDCacheFromWax()
            if let cached = newestKnownFrameID(for: threadID) {
                return try await loadCheckpoint(frameID: cached.frameID, includePending: cached.includePending)
            }
        }
        return nil
    }

    private func loadCheckpoint(frameID: UInt64, includePending: Bool) async throws -> HiveCheckpoint<Schema> {
        let payload: Data
        if includePending {
            payload = try await wax.frameContentIncludingPending(frameId: frameID)
        } else {
            payload = try await wax.frameContent(frameId: frameID)
        }
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }

    private func newestKnownFrameID(for threadID: HiveThreadID) -> (frameID: UInt64, includePending: Bool)? {
        let latestCommitted = latestFrameIDByThreadID[threadID]
        let latestPending = pendingFrameIDByThreadID[threadID]

        switch (latestCommitted, latestPending) {
        case let (.some(committed), .some(pending)):
            return pending > committed ? (pending, true) : (committed, false)
        case let (.some(committed), .none):
            return (committed, false)
        case let (.none, .some(pending)):
            return (pending, true)
        case (.none, .none):
            return nil
        }
    }

    private func rebuildLatestFrameIDCacheFromWax() async {
        let metas = await wax.frameMetas()

        var rebuilt: [HiveThreadID: UInt64] = [:]
        for meta in metas {
            guard meta.kind == Self.checkpointKind else { continue }
            guard let metadata = meta.metadata?.entries else { continue }
            guard let threadRawValue = metadata[HiveCheckpointWaxMetadataKey.threadID] else { continue }

            let threadID = HiveThreadID(threadRawValue)
            if let current = rebuilt[threadID] {
                if meta.id > current {
                    rebuilt[threadID] = meta.id
                }
            } else {
                rebuilt[threadID] = meta.id
            }
        }

        latestFrameIDByThreadID = rebuilt
        hasScannedAllCheckpointFrames = true
    }

    private func updatePendingFrameIDCache(threadID: HiveThreadID, frameID: UInt64) {
        if let current = pendingFrameIDByThreadID[threadID] {
            if frameID > current {
                pendingFrameIDByThreadID[threadID] = frameID
            }
        } else {
            pendingFrameIDByThreadID[threadID] = frameID
        }
    }

    private func mergePendingFrameIDCacheIntoLatest() {
        for (threadID, frameID) in pendingFrameIDByThreadID {
            if let current = latestFrameIDByThreadID[threadID] {
                if frameID > current {
                    latestFrameIDByThreadID[threadID] = frameID
                }
            } else {
                latestFrameIDByThreadID[threadID] = frameID
            }
        }
        pendingFrameIDByThreadID.removeAll(keepingCapacity: true)
    }
}
