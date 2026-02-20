import Foundation

/// A single memory item stored in a memory store.
public struct HiveMemoryItem: Sendable, Codable, Equatable {
    public let namespace: [String]
    public let key: String
    public let text: String
    public let metadata: [String: String]
    public let score: Double?

    public init(
        namespace: [String],
        key: String,
        text: String,
        metadata: [String: String] = [:],
        score: Double? = nil
    ) {
        self.namespace = namespace
        self.key = key
        self.text = text
        self.metadata = metadata
        self.score = score
    }
}

/// Storage backend for cross-thread semantic memory.
public protocol HiveMemoryStore: Sendable {
    func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws
    func get(namespace: [String], key: String) async throws -> HiveMemoryItem?
    func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem]
    func delete(namespace: [String], key: String) async throws
}

/// Type-erased memory store wrapper.
public struct AnyHiveMemoryStore: Sendable {
    private let _remember: @Sendable ([String], String, String, [String: String]) async throws -> Void
    private let _get: @Sendable ([String], String) async throws -> HiveMemoryItem?
    private let _recall: @Sendable ([String], String, Int) async throws -> [HiveMemoryItem]
    private let _delete: @Sendable ([String], String) async throws -> Void

    public init<S: HiveMemoryStore>(_ store: S) {
        self._remember = { ns, key, text, meta in try await store.remember(namespace: ns, key: key, text: text, metadata: meta) }
        self._get = { ns, key in try await store.get(namespace: ns, key: key) }
        self._recall = { ns, query, limit in try await store.recall(namespace: ns, query: query, limit: limit) }
        self._delete = { ns, key in try await store.delete(namespace: ns, key: key) }
    }

    public func remember(namespace: [String], key: String, text: String, metadata: [String: String] = [:]) async throws {
        try await _remember(namespace, key, text, metadata)
    }

    public func get(namespace: [String], key: String) async throws -> HiveMemoryItem? {
        try await _get(namespace, key)
    }

    public func recall(namespace: [String], query: String, limit: Int = 10) async throws -> [HiveMemoryItem] {
        try await _recall(namespace, query, limit)
    }

    public func delete(namespace: [String], key: String) async throws {
        try await _delete(namespace, key)
    }
}
