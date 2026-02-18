import Foundation
import Testing
import Wax
@testable import HiveRAGWax

private func makeTempWaxURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hive-ragwax-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("wax.wax")
}

@Suite("HiveRAGWaxStore")
struct HiveRAGWaxStoreTests {
    @Test func rememberAndGet() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["users"], key: "u1", text: "Alice likes coffee", metadata: ["role": "admin"])
        let item = try await store.get(namespace: ["users"], key: "u1")
        #expect(item != nil)
        #expect(item?.text == "Alice likes coffee")
        #expect(item?.metadata["role"] == "admin")
    }

    @Test func getNonExistent() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        let item = try await store.get(namespace: ["users"], key: "missing")
        #expect(item == nil)
    }

    @Test func recallKeywordMatch() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["docs"], key: "d1", text: "Swift concurrency with actors", metadata: [:])
        try await store.remember(namespace: ["docs"], key: "d2", text: "Python asyncio event loop", metadata: [:])
        let results = try await store.recall(namespace: ["docs"], query: "Swift actors", limit: 10)
        #expect(results.count >= 1)
        #expect(results.contains { $0.key == "d1" })
    }

    @Test func deleteItem() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["ns"], key: "k1", text: "hello", metadata: [:])
        try await store.delete(namespace: ["ns"], key: "k1")
        let item = try await store.get(namespace: ["ns"], key: "k1")
        #expect(item == nil)
    }

    @Test func namespaceIsolation() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["nsA"], key: "k1", text: "visible content A", metadata: [:])
        try await store.remember(namespace: ["nsB"], key: "k2", text: "visible content B", metadata: [:])
        let resultsA = try await store.recall(namespace: ["nsA"], query: "visible content", limit: 10)
        #expect(resultsA.allSatisfy { $0.namespace == ["nsA"] })
        let resultsB = try await store.recall(namespace: ["nsB"], query: "visible content", limit: 10)
        #expect(resultsB.allSatisfy { $0.namespace == ["nsB"] })
    }

    @Test func overwriteSameKey() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["ns"], key: "k1", text: "original", metadata: [:])
        try await store.remember(namespace: ["ns"], key: "k1", text: "updated", metadata: ["new": "meta"])
        let item = try await store.get(namespace: ["ns"], key: "k1")
        #expect(item?.text == "updated")
        #expect(item?.metadata["new"] == "meta")
    }

    @Test func recallSkipsDeletedFrames() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["ns"], key: "k1", text: "alpha note", metadata: [:])
        try await store.delete(namespace: ["ns"], key: "k1")

        let results = try await store.recall(namespace: ["ns"], query: "alpha", limit: 10)
        #expect(results.isEmpty)
    }

    @Test func recallUsesLatestRevisionPerKey() async throws {
        let url = try makeTempWaxURL()
        let store = try await HiveRAGWaxStore.create(at: url)
        try await store.remember(namespace: ["ns"], key: "k1", text: "alpha note", metadata: [:])
        try await store.remember(namespace: ["ns"], key: "k1", text: "beta note", metadata: [:])

        let oldQueryResults = try await store.recall(namespace: ["ns"], query: "alpha", limit: 10)
        #expect(oldQueryResults.isEmpty)

        let latestQueryResults = try await store.recall(namespace: ["ns"], query: "beta", limit: 10)
        #expect(latestQueryResults.count == 1)
        #expect(latestQueryResults.first?.key == "k1")
        #expect(latestQueryResults.first?.text == "beta note")
    }
}
