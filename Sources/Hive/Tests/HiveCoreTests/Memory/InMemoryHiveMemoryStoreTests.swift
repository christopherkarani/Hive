import Testing
@testable import HiveCore

@Suite("InMemoryHiveMemoryStore")
struct InMemoryHiveMemoryStoreTests {
    @Test func rememberAndGet() async throws {
        let store = InMemoryHiveMemoryStore()
        try await store.remember(namespace: ["users"], key: "user1", text: "Alice likes coffee", metadata: ["role": "admin"])
        let item = try await store.get(namespace: ["users"], key: "user1")
        #expect(item != nil)
        #expect(item?.text == "Alice likes coffee")
        #expect(item?.metadata["role"] == "admin")
        #expect(item?.namespace == ["users"])
        #expect(item?.key == "user1")
    }

    @Test func getNonExistent() async throws {
        let store = InMemoryHiveMemoryStore()
        let item = try await store.get(namespace: ["users"], key: "missing")
        #expect(item == nil)
    }

    @Test func recallKeywordMatch() async throws {
        let store = InMemoryHiveMemoryStore()
        try await store.remember(namespace: ["docs"], key: "d1", text: "Swift concurrency with actors", metadata: [:])
        try await store.remember(namespace: ["docs"], key: "d2", text: "Python asyncio event loop", metadata: [:])
        let results = try await store.recall(namespace: ["docs"], query: "Swift actors", limit: 10)
        #expect(results.count == 1)
        #expect(results[0].key == "d1")
        #expect(results[0].score != nil)
        #expect(results[0].score! > 0)
    }

    @Test func deleteItem() async throws {
        let store = InMemoryHiveMemoryStore()
        try await store.remember(namespace: ["ns"], key: "k1", text: "hello", metadata: [:])
        try await store.delete(namespace: ["ns"], key: "k1")
        let item = try await store.get(namespace: ["ns"], key: "k1")
        #expect(item == nil)
    }

    @Test func namespaceIsolation() async throws {
        let store = InMemoryHiveMemoryStore()
        try await store.remember(namespace: ["nsA"], key: "k1", text: "visible in A", metadata: [:])
        try await store.remember(namespace: ["nsB"], key: "k2", text: "visible in B", metadata: [:])
        let resultsA = try await store.recall(namespace: ["nsA"], query: "visible", limit: 10)
        let resultsB = try await store.recall(namespace: ["nsB"], query: "visible", limit: 10)
        #expect(resultsA.count == 1)
        #expect(resultsA[0].key == "k1")
        #expect(resultsB.count == 1)
        #expect(resultsB[0].key == "k2")
    }

    @Test func overwriteSameKey() async throws {
        let store = InMemoryHiveMemoryStore()
        try await store.remember(namespace: ["ns"], key: "k1", text: "original", metadata: [:])
        try await store.remember(namespace: ["ns"], key: "k1", text: "updated", metadata: ["new": "meta"])
        let item = try await store.get(namespace: ["ns"], key: "k1")
        #expect(item?.text == "updated")
        #expect(item?.metadata["new"] == "meta")
    }

    @Test func typeErasedWrapper() async throws {
        let store = InMemoryHiveMemoryStore()
        let anyStore = AnyHiveMemoryStore(store)
        try await anyStore.remember(namespace: ["ns"], key: "k1", text: "through wrapper", metadata: [:])
        let item = try await anyStore.get(namespace: ["ns"], key: "k1")
        #expect(item?.text == "through wrapper")
    }
}
