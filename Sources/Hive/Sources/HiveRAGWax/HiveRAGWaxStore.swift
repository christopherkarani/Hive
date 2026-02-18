import Foundation
import HiveCore
import Wax

private enum HiveRAGWaxMetadataKey {
    static let namespace = "hive.memory.namespace"
    static let key = "hive.memory.key"
    static let metaPrefix = "hive.memory.meta."
}

/// Wax-backed memory store implementation.
public actor HiveRAGWaxStore: HiveMemoryStore {
    private static var memoryKind: String { "hive.memory" }

    private let wax: Wax

    public init(wax: Wax) {
        self.wax = wax
    }

    public static func create(
        at url: URL,
        walSize: UInt64 = Constants.defaultWalSize,
        options: WaxOptions = .init()
    ) async throws -> HiveRAGWaxStore {
        let wax = try await Wax.create(at: url, walSize: walSize, options: options)
        return HiveRAGWaxStore(wax: wax)
    }

    public static func open(
        at url: URL,
        options: WaxOptions = .init()
    ) async throws -> HiveRAGWaxStore {
        let wax = try await Wax.open(at: url, options: options)
        return HiveRAGWaxStore(wax: wax)
    }

    public func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws {
        if let existingFrame = await findLatestActiveFrame(namespace: namespace, key: key) {
            try await wax.delete(frameId: existingFrame.id)
        }

        let data = Data(text.utf8)
        var metadataEntries: [String: String] = [
            HiveRAGWaxMetadataKey.namespace: namespace.joined(separator: "/"),
            HiveRAGWaxMetadataKey.key: key,
        ]
        for (k, v) in metadata {
            metadataEntries[HiveRAGWaxMetadataKey.metaPrefix + k] = v
        }

        let frameOptions = FrameMetaSubset(
            kind: Self.memoryKind,
            metadata: Metadata(metadataEntries)
        )
        _ = try await wax.put(data, options: frameOptions, compression: .plain)
        try await wax.commit()
    }

    public func get(namespace: [String], key: String) async throws -> HiveMemoryItem? {
        guard let frame = await findLatestActiveFrame(namespace: namespace, key: key) else {
            return nil
        }
        let payload = try await wax.frameContent(frameId: frame.id)
        let text = String(decoding: payload, as: UTF8.self)
        let userMeta = extractUserMetadata(from: frame)

        return HiveMemoryItem(
            namespace: namespace,
            key: key,
            text: text,
            metadata: userMeta,
            score: nil
        )
    }

    public func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem] {
        let nsString = namespace.joined(separator: "/")
        let activeFramesByKey = await latestActiveFramesByKey(in: nsString)
        let queryWords = query.lowercased().split(separator: " ").map(String.init)

        var results: [(item: HiveMemoryItem, score: Float, frameID: UInt64)] = []

        for (itemKey, frame) in activeFramesByKey {
            let payload = try await wax.frameContent(frameId: frame.id)
            let text = String(decoding: payload, as: UTF8.self)
            let textLower = text.lowercased()

            let matchCount = queryWords.filter { textLower.contains($0) }.count
            guard matchCount > 0 else { continue }

            let score = Float(matchCount) / Float(max(queryWords.count, 1))
            let userMeta = extractUserMetadata(from: frame)

            results.append((
                item: HiveMemoryItem(
                    namespace: namespace,
                    key: itemKey,
                    text: text,
                    metadata: userMeta,
                    score: score
                ),
                score: score,
                frameID: frame.id
            ))
        }

        results.sort {
            if $0.score == $1.score {
                return $0.frameID > $1.frameID
            }
            return $0.score > $1.score
        }
        return Array(results.prefix(limit).map(\.item))
    }

    public func delete(namespace: [String], key: String) async throws {
        guard let frame = await findLatestActiveFrame(namespace: namespace, key: key) else { return }
        try await wax.delete(frameId: frame.id)
        try await wax.commit()
    }

    // MARK: - Private

    private func findLatestActiveFrame(namespace: [String], key: String) async -> FrameMeta? {
        let nsString = namespace.joined(separator: "/")
        let framesByKey = await latestActiveFramesByKey(in: nsString)
        return framesByKey[key]
    }

    private func latestActiveFramesByKey(in namespace: String) async -> [String: FrameMeta] {
        let metas = await wax.frameMetas()
        var latestByKey: [String: FrameMeta] = [:]

        for meta in metas {
            guard isActiveCurrentFrame(meta, namespace: namespace) else { continue }
            guard let key = meta.metadata?.entries[HiveRAGWaxMetadataKey.key] else { continue }

            if let existing = latestByKey[key], existing.id > meta.id {
                continue
            }
            latestByKey[key] = meta
        }

        return latestByKey
    }

    private func isActiveCurrentFrame(_ meta: FrameMeta, namespace: String) -> Bool {
        guard meta.kind == Self.memoryKind else { return false }
        guard meta.status == .active else { return false }
        guard meta.supersededBy == nil else { return false }
        guard let entries = meta.metadata?.entries else { return false }
        return entries[HiveRAGWaxMetadataKey.namespace] == namespace
    }

    private func extractUserMetadata(from meta: FrameMeta) -> [String: String] {
        guard let entries = meta.metadata?.entries else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in entries {
            if k.hasPrefix(HiveRAGWaxMetadataKey.metaPrefix) {
                let userKey = String(k.dropFirst(HiveRAGWaxMetadataKey.metaPrefix.count))
                result[userKey] = v
            }
        }
        return result
    }
}
