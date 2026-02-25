---
sidebar_position: 2
title: Data Structures
description: HiveBitset and HiveInvertedIndex internal data structures.
---

# Data Structures

## HiveBitset

Compact, fixed-size dynamic bitset backed by `[UInt64]`:

```swift
struct HiveBitset: Sendable, Equatable {
    init(bitCapacity: Int)
    mutating func insert(_ bitIndex: Int)
    func contains(_ bitIndex: Int) -> Bool
    var isEmpty: Bool
}
```

- O(1) insert and contains operations
- Used by the runtime for efficient join barrier tracking
- Each join edge maps parent node completions to bit positions
- When all bits are set, the join barrier fires

## HiveInvertedIndex

BM25-style inverted index for in-memory text search:

```swift
struct HiveInvertedIndex: Sendable {
    mutating func upsert(docID: String, text: String)
    mutating func remove(docID: String)
    func query(terms: [String], limit: Int) -> [(docID: String, score: Double)]
    static func tokenize(_ text: String) -> [String]
}
```

### BM25 Parameters

- **k1** = 1.2 (term frequency saturation)
- **b** = 0.75 (document length normalization)

### Usage

Used by `InMemoryHiveMemoryStore` for semantic recall. The `tokenize` function lowercases and splits on non-alphanumeric boundaries.

```swift
var index = HiveInvertedIndex()
index.upsert(docID: "doc1", text: "Swift concurrency with actors")
index.upsert(docID: "doc2", text: "Actor isolation in Swift")

let results = index.query(terms: ["swift", "actors"], limit: 10)
// [(docID: "doc1", score: 1.23), (docID: "doc2", score: 0.98)]
```
