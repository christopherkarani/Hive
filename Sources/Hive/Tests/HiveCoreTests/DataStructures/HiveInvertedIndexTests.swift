import Testing
@testable import HiveCore

@Suite("HiveInvertedIndex")
struct HiveInvertedIndexTests {
    @Test("empty index returns no results")
    func emptyIndexReturnsNoResults() {
        let index = HiveInvertedIndex()
        let results = index.query(terms: ["swift"], limit: 10)
        #expect(results.isEmpty)
    }

    @Test("query with empty terms returns no results")
    func queryWithEmptyTermsReturnsNoResults() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors")
        let results = index.query(terms: [], limit: 10)
        #expect(results.isEmpty)
    }

    @Test("query with limit zero returns no results")
    func queryWithLimitZeroReturnsNoResults() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors")
        let results = index.query(terms: ["swift"], limit: 0)
        #expect(results.isEmpty)
    }

    @Test("upsert and query single document")
    func upsertAndQuerySingleDocument() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift concurrency actors")
        let results = index.query(terms: ["swift"], limit: 10)
        #expect(results.count == 1)
        #expect(results[0].docID == "d1")
        #expect(results[0].score > 0)
    }

    @Test("scores are Double precision, not Float")
    func scoresAreDoublePrecision() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors swift concurrency swift")
        index.upsert(docID: "d2", text: "swift")
        let results = index.query(terms: ["swift", "actors"], limit: 10)
        #expect(results.count == 2)
        // Scores must be Double — verify type matches without precision loss
        let score: Double = results[0].score
        #expect(score > 0)
    }

    @Test("remove nonexistent doc is a no-op")
    func removeNonexistentDocIsNoOp() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors")
        // Removing a doc that was never inserted should not crash or corrupt state
        index.remove(docID: "nonexistent")
        #expect(index.totalDocs == 1)
        let results = index.query(terms: ["swift"], limit: 10)
        #expect(results.count == 1)
    }

    @Test("remove existing doc removes it from query results")
    func removeExistingDocRemovesFromResults() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors")
        index.upsert(docID: "d2", text: "python asyncio")
        index.remove(docID: "d1")
        #expect(index.totalDocs == 1)
        let results = index.query(terms: ["swift"], limit: 10)
        #expect(results.isEmpty)
    }

    @Test("remove cleans up posting list when no docs remain for a term")
    func removeCleanUpPostingList() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "uniqueterm")
        index.remove(docID: "d1")
        #expect(index.postingsByTerm["uniqueterm"] == nil)
        #expect(index.totalDocLength == 0)
    }

    @Test("upsert same docID replaces previous text")
    func upsertSameDocIDReplacesPreviousText() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "d1", text: "swift actors")
        index.upsert(docID: "d1", text: "python asyncio")
        #expect(index.totalDocs == 1)
        let swiftResults = index.query(terms: ["swift"], limit: 10)
        #expect(swiftResults.isEmpty)
        let pythonResults = index.query(terms: ["python"], limit: 10)
        #expect(pythonResults.count == 1)
    }

    @Test("limit is respected")
    func limitIsRespected() {
        var index = HiveInvertedIndex()
        for i in 0..<10 {
            index.upsert(docID: "d\(i)", text: "swift actors concurrency")
        }
        let results = index.query(terms: ["swift"], limit: 3)
        #expect(results.count == 3)
    }

    @Test("tie-breaking uses lexicographic docID order")
    func tieBrakingUsesLexicographicOrder() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "z", text: "swift actors")
        index.upsert(docID: "a", text: "swift actors")
        index.upsert(docID: "m", text: "swift actors")
        let results = index.query(terms: ["swift", "actors"], limit: 10)
        #expect(results.map(\.docID) == ["a", "m", "z"])
    }

    @Test("higher term frequency produces higher score")
    func higherTermFrequencyProducesHigherScore() {
        var index = HiveInvertedIndex()
        index.upsert(docID: "dense", text: "swift swift swift actors")
        index.upsert(docID: "sparse", text: "swift actors")
        let results = index.query(terms: ["swift"], limit: 10)
        #expect(results.count == 2)
        #expect(results[0].docID == "dense")
        #expect(results[0].score > results[1].score)
    }

    @Test("tokenize lowercases and splits on non-alphanumeric")
    func tokenizeLowercasesAndSplits() {
        let tokens = HiveInvertedIndex.tokenize("Hello, World! Swift3.0")
        #expect(tokens == ["hello", "world", "swift3", "0"])
    }
}
