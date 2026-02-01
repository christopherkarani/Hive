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

    private static func lexicographicallyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

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
            HiveCheckpointWaxMetadataKey.runID: checkpoint.runID.rawValue.uuidString.lowercased()
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

        var best: (frameId: UInt64, stepIndex: Int, checkpointID: String)?
        for meta in metas {
            guard let metadata = meta.metadata?.entries else { continue }
            guard metadata[HiveCheckpointWaxMetadataKey.threadID] == threadID.rawValue else { continue }
            guard let stepString = metadata[HiveCheckpointWaxMetadataKey.stepIndex],
                  let stepIndex = Int(stepString) else { continue }
            guard let checkpointID = metadata[HiveCheckpointWaxMetadataKey.checkpointID] else { continue }

            if let current = best {
                if stepIndex > current.stepIndex {
                    best = (meta.id, stepIndex, checkpointID)
                } else if stepIndex == current.stepIndex,
                          Self.lexicographicallyPrecedes(current.checkpointID, checkpointID) {
                    best = (meta.id, stepIndex, checkpointID)
                }
            } else {
                best = (meta.id, stepIndex, checkpointID)
            }
        }

        guard let best else { return nil }
        let payload = try await wax.frameContent(frameId: best.frameId)
        return try decoder.decode(HiveCheckpoint<Schema>.self, from: payload)
    }
}
