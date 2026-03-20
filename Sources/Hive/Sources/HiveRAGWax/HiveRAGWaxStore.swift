import Foundation
import HiveCore
import Wax

private enum HiveRAGWaxMetadataKey {
    static let namespace = "hive.memory.namespace"
    static let key = "hive.memory.key"
    static let metaPrefix = "hive.memory.meta."
}

private actor HiveRAGWaxFrameStoreRegistry {
    static let shared = HiveRAGWaxFrameStoreRegistry()

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

/// Wax-backed memory store implementation.
public actor HiveRAGWaxStore: HiveMemoryStore {
    private static var memoryKind: String { "hive.memory" }

    private let frames: FrameStore

    public init(frames: FrameStore) {
        self.frames = frames
    }

    public static func create(
        at url: URL,
        walSize: UInt64 = FrameStore.defaultWalSize
    ) async throws -> HiveRAGWaxStore {
        let frames = try await HiveRAGWaxFrameStoreRegistry.shared.create(at: url, walSize: walSize)
        return HiveRAGWaxStore(frames: frames)
    }

    public static func open(at url: URL) async throws -> HiveRAGWaxStore {
        let frames = try await HiveRAGWaxFrameStoreRegistry.shared.open(at: url)
        return HiveRAGWaxStore(frames: frames)
    }

    public func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws {
        if let existingFrame = await findLatestActiveFrame(namespace: namespace, key: key) {
            try await frames.delete(frameID: existingFrame.id)
        }

        let data = Data(text.utf8)
        let encodedNamespace = encodeNamespace(namespace)
        var metadataEntries: [String: String] = [
            HiveRAGWaxMetadataKey.namespace: encodedNamespace,
            HiveRAGWaxMetadataKey.key: key,
        ]
        for (metaKey, metaValue) in metadata {
            metadataEntries[HiveRAGWaxMetadataKey.metaPrefix + metaKey] = metaValue
        }

        _ = try await frames.put(data, kind: Self.memoryKind, metadata: metadataEntries)
    }

    public func get(namespace: [String], key: String) async throws -> HiveMemoryItem? {
        guard let frame = await findLatestActiveFrame(namespace: namespace, key: key) else {
            return nil
        }

        let payload = try await frames.content(frameID: frame.id)
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
        guard limit > 0 else { return [] }

        let normalizedQueryWords = query.lowercased().split(separator: " ").map(String.init)
        guard normalizedQueryWords.isEmpty == false else { return [] }

        let nsString = encodeNamespace(namespace)
        let activeFramesByKey = await latestActiveFramesByKey(in: nsString)
        var results: [(item: HiveMemoryItem, score: Double, frameID: UInt64)] = []
        results.reserveCapacity(activeFramesByKey.count)

        for (itemKey, frame) in activeFramesByKey {
            let payload = try await frames.content(frameID: frame.id)
            let text = String(decoding: payload, as: UTF8.self)
            let textLower = text.lowercased()

            let matchCount = normalizedQueryWords.filter { textLower.contains($0) }.count
            guard matchCount > 0 else { continue }

            let score = Double(matchCount) / Double(normalizedQueryWords.count)
            results.append((
                item: HiveMemoryItem(
                    namespace: namespace,
                    key: itemKey,
                    text: text,
                    metadata: extractUserMetadata(from: frame),
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
        try await frames.delete(frameID: frame.id)
    }

    private func findLatestActiveFrame(namespace: [String], key: String) async -> FrameStore.Frame? {
        let nsString = encodeNamespace(namespace)
        let framesByKey = await latestActiveFramesByKey(in: nsString)
        return framesByKey[key]
    }

    private func latestActiveFramesByKey(in namespace: String) async -> [String: FrameStore.Frame] {
        let allFrames = await frames.frames()
        var latestByKey: [String: FrameStore.Frame] = [:]

        for frame in allFrames {
            guard isActiveCurrentFrame(frame, namespace: namespace) else { continue }
            guard let key = frame.metadata[HiveRAGWaxMetadataKey.key] else { continue }

            if let existing = latestByKey[key], existing.id > frame.id {
                continue
            }
            latestByKey[key] = frame
        }

        return latestByKey
    }

    private func isActiveCurrentFrame(_ frame: FrameStore.Frame, namespace: String) -> Bool {
        guard frame.kind == Self.memoryKind else { return false }
        guard frame.status == .active else { return false }
        guard frame.supersededBy == nil else { return false }
        return frame.metadata[HiveRAGWaxMetadataKey.namespace] == namespace
    }

    private func extractUserMetadata(from frame: FrameStore.Frame) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in frame.metadata {
            guard key.hasPrefix(HiveRAGWaxMetadataKey.metaPrefix) else { continue }
            let userKey = String(key.dropFirst(HiveRAGWaxMetadataKey.metaPrefix.count))
            result[userKey] = value
        }
        return result
    }

    private func encodeNamespace(_ namespace: [String]) -> String {
        namespace.map(escapeNamespaceComponent).joined(separator: "/")
    }

    private func escapeNamespaceComponent(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
    }
}
