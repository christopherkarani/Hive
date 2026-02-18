import Foundation

/// In-memory implementation of ``HiveMemoryStore`` for testing.
public actor InMemoryHiveMemoryStore: HiveMemoryStore {
    private var storage: [String: HiveMemoryItem] = [:]

    public init() {}

    private func storageKey(namespace: [String], key: String) -> String {
        (namespace + [key]).joined(separator: "/")
    }

    public func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws {
        let item = HiveMemoryItem(namespace: namespace, key: key, text: text, metadata: metadata, score: nil)
        storage[storageKey(namespace: namespace, key: key)] = item
    }

    public func get(namespace: [String], key: String) async throws -> HiveMemoryItem? {
        storage[storageKey(namespace: namespace, key: key)]
    }

    public func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem] {
        let prefix = namespace.joined(separator: "/") + "/"
        let queryWords = query.lowercased().split(separator: " ").map(String.init)

        var results: [(item: HiveMemoryItem, score: Float)] = []
        for (key, item) in storage {
            guard key.hasPrefix(prefix) else { continue }
            let textLower = item.text.lowercased()
            let matchCount = queryWords.filter { textLower.contains($0) }.count
            if matchCount > 0 {
                let score = Float(matchCount) / Float(max(queryWords.count, 1))
                results.append((item: HiveMemoryItem(
                    namespace: item.namespace,
                    key: item.key,
                    text: item.text,
                    metadata: item.metadata,
                    score: score
                ), score: score))
            }
        }

        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit).map(\.item))
    }

    public func delete(namespace: [String], key: String) async throws {
        storage.removeValue(forKey: storageKey(namespace: namespace, key: key))
    }
}
