import Foundation
import Wax

/// Codable, checkpoint-friendly representation of a Wax RAG item.
public struct HiveRAGSnippet: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case snippet
        case expanded
        case surrogate
    }

    public enum Source: String, Codable, Sendable, Equatable {
        case text
        case vector
        case timeline
        case structuredMemory
    }

    public let kind: Kind
    public let frameID: UInt64
    public let score: Float
    public let sources: [Source]
    public let text: String

    public init(
        kind: Kind,
        frameID: UInt64,
        score: Float,
        sources: [Source],
        text: String
    ) {
        self.kind = kind
        self.frameID = frameID
        self.score = score
        self.sources = sources
        self.text = text
    }
}

extension HiveRAGSnippet {
    init(_ item: RAGContext.Item) {
        self.init(
            kind: Kind(item.kind),
            frameID: item.frameId,
            score: item.score,
            sources: item.sources.map(Source.init),
            text: item.text
        )
    }
}

extension HiveRAGSnippet.Kind {
    init(_ kind: RAGContext.ItemKind) {
        switch kind {
        case .snippet:
            self = .snippet
        case .expanded:
            self = .expanded
        case .surrogate:
            self = .surrogate
        }
    }
}

extension HiveRAGSnippet.Source {
    init(_ source: SearchResponse.Source) {
        switch source {
        case .text:
            self = .text
        case .vector:
            self = .vector
        case .timeline:
            self = .timeline
        case .structuredMemory:
            self = .structuredMemory
        }
    }
}

