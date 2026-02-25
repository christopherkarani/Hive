import Foundation

/// In-memory implementation of ``HiveMemoryStore`` for testing.
public actor InMemoryHiveMemoryStore: HiveMemoryStore {
    private var storage: [String: HiveMemoryItem] = [:]
    private var indexesByNamespace: [String: HiveInvertedIndex] = [:]

    public init() {}

    private func escapePathComponent(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: "#", with: "%23")
    }

    private func storageKey(namespace: [String], key: String) -> String {
        namespaceKey(namespace) + "#" + escapePathComponent(key)
    }

    private func namespaceKey(_ namespace: [String]) -> String {
        namespace.map(escapePathComponent).joined(separator: "/")
    }

    public func remember(namespace: [String], key: String, text: String, metadata: [String: String]) async throws {
        let nsKey = namespaceKey(namespace)
        let docID = storageKey(namespace: namespace, key: key)
        let item = HiveMemoryItem(namespace: namespace, key: key, text: text, metadata: metadata, score: nil)
        storage[docID] = item

        var index = indexesByNamespace[nsKey] ?? HiveInvertedIndex()
        index.upsert(docID: docID, text: text)
        indexesByNamespace[nsKey] = index
    }

    public func get(namespace: [String], key: String) async throws -> HiveMemoryItem? {
        storage[storageKey(namespace: namespace, key: key)]
    }

    public func recall(namespace: [String], query: String, limit: Int) async throws -> [HiveMemoryItem] {
        let nsKey = namespaceKey(namespace)
        guard let index = indexesByNamespace[nsKey] else { return [] }

        let prefix = nsKey + "#"
        let queryTerms = HiveInvertedIndex.tokenize(query)
        let ranked = index.query(terms: queryTerms, limit: limit)
        var results: [HiveMemoryItem] = []
        results.reserveCapacity(ranked.count)
        for entry in ranked {
            guard entry.docID.hasPrefix(prefix) else { continue }
            guard let item = storage[entry.docID] else { continue }
            results.append(
                HiveMemoryItem(
                    namespace: item.namespace,
                    key: item.key,
                    text: item.text,
                    metadata: item.metadata,
                    score: entry.score
                )
            )
        }
        return results
    }

    public func delete(namespace: [String], key: String) async throws {
        let nsKey = namespaceKey(namespace)
        let docID = storageKey(namespace: namespace, key: key)
        storage.removeValue(forKey: docID)

        guard var index = indexesByNamespace[nsKey] else { return }
        index.remove(docID: docID)
        if index.totalDocs == 0 {
            indexesByNamespace.removeValue(forKey: nsKey)
        } else {
            indexesByNamespace[nsKey] = index
        }
    }
}
