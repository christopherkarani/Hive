import Foundation

/// Lightweight BM25-style inverted index for in-memory recall.
struct HiveInvertedIndex: Sendable {
    private(set) var postingsByTerm: [String: [String: Int]] = [:]
    private(set) var termFrequenciesByDocID: [String: [String: Int]] = [:]
    private(set) var docLengthByDocID: [String: Int] = [:]
    private(set) var totalDocLength: Int = 0

    var totalDocs: Int {
        docLengthByDocID.count
    }

    var avgDocLength: Double {
        guard totalDocs > 0 else { return 0 }
        return Double(totalDocLength) / Double(totalDocs)
    }

    mutating func upsert(docID: String, text: String) {
        if docLengthByDocID[docID] != nil {
            remove(docID: docID)
        }

        let terms = Self.tokenize(text)
        let termFrequencies = Self.termFrequencies(terms)
        termFrequenciesByDocID[docID] = termFrequencies
        docLengthByDocID[docID] = terms.count
        totalDocLength += terms.count

        for (term, frequency) in termFrequencies {
            postingsByTerm[term, default: [:]][docID] = frequency
        }
    }

    mutating func remove(docID: String) {
        guard let termFrequencies = termFrequenciesByDocID.removeValue(forKey: docID),
              let length = docLengthByDocID.removeValue(forKey: docID) else {
            return
        }

        totalDocLength -= length
        for term in termFrequencies.keys {
            postingsByTerm[term]?[docID] = nil
            if postingsByTerm[term]?.isEmpty == true {
                postingsByTerm[term] = nil
            }
        }
    }

    func query(terms: [String], limit: Int) -> [(docID: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard totalDocs > 0 else { return [] }
        guard terms.isEmpty == false else { return [] }

        let k1 = 1.2
        let b = 0.75
        let avgdl = max(avgDocLength, 1e-9)
        let normalizedTerms = terms.map { $0.lowercased() }

        var scoresByDocID: [String: Double] = [:]
        for term in normalizedTerms {
            guard let postings = postingsByTerm[term], postings.isEmpty == false else { continue }

            let docFrequency = postings.count
            let idf = log(1.0 + ((Double(totalDocs - docFrequency) + 0.5) / (Double(docFrequency) + 0.5)))
            for (docID, termFrequency) in postings {
                let tf = Double(termFrequency)
                let docLength = Double(docLengthByDocID[docID] ?? 0)
                let denominator = tf + k1 * (1.0 - b + b * (docLength / avgdl))
                guard denominator > 0 else { continue }
                let score = idf * ((tf * (k1 + 1.0)) / denominator)
                scoresByDocID[docID, default: 0] += score
            }
        }

        return scoresByDocID
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return HiveOrdering.lexicographicallyPrecedes(lhs.key, rhs.key)
                }
                return lhs.value > rhs.value
            }
            .prefix(limit)
            .map { (docID: $0.key, score: Float($0.value)) }
    }

    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .split(whereSeparator: { $0.isLetter == false && $0.isNumber == false })
            .map(String.init)
    }

    private static func termFrequencies(_ terms: [String]) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        frequencies.reserveCapacity(terms.count)
        for term in terms {
            frequencies[term, default: 0] += 1
        }
        return frequencies
    }
}
