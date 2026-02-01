import Foundation

/// Stable identifier for a checkpoint.
public struct HiveCheckpointID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Persisted frontier task snapshot.
public struct HiveCheckpointTask: Codable, Sendable {
    public let provenance: HiveTaskProvenance
    public let nodeID: HiveNodeID
    public let localFingerprint: Data
    public let localDataByChannelID: [String: Data]

    public init(
        provenance: HiveTaskProvenance,
        nodeID: HiveNodeID,
        localFingerprint: Data,
        localDataByChannelID: [String: Data]
    ) {
        self.provenance = provenance
        self.nodeID = nodeID
        self.localFingerprint = localFingerprint
        self.localDataByChannelID = localDataByChannelID
    }
}

/// Persisted snapshot of runtime state for resume.
public struct HiveCheckpoint<Schema: HiveSchema>: Codable, Sendable {
    public let id: HiveCheckpointID
    public let threadID: HiveThreadID
    public let runID: HiveRunID
    public let stepIndex: Int
    public let schemaVersion: String
    public let graphVersion: String
    public let globalDataByChannelID: [String: Data]
    public let frontier: [HiveCheckpointTask]
    public let joinBarrierSeenByJoinID: [String: [String]]
    public let interruption: HiveInterrupt<Schema>?

    public init(
        id: HiveCheckpointID,
        threadID: HiveThreadID,
        runID: HiveRunID,
        stepIndex: Int,
        schemaVersion: String,
        graphVersion: String,
        globalDataByChannelID: [String: Data],
        frontier: [HiveCheckpointTask],
        joinBarrierSeenByJoinID: [String: [String]],
        interruption: HiveInterrupt<Schema>?
    ) {
        self.id = id
        self.threadID = threadID
        self.runID = runID
        self.stepIndex = stepIndex
        self.schemaVersion = schemaVersion
        self.graphVersion = graphVersion
        self.globalDataByChannelID = globalDataByChannelID
        self.frontier = frontier
        self.joinBarrierSeenByJoinID = joinBarrierSeenByJoinID
        self.interruption = interruption
    }
}

/// Storage backend for checkpoints.
public protocol HiveCheckpointStore: Sendable {
    associatedtype Schema: HiveSchema
    func save(_ checkpoint: HiveCheckpoint<Schema>) async throws
    func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>?
}

/// Type-erased checkpoint store wrapper.
public struct AnyHiveCheckpointStore<Schema: HiveSchema>: Sendable {
    private let _save: @Sendable (HiveCheckpoint<Schema>) async throws -> Void
    private let _loadLatest: @Sendable (HiveThreadID) async throws -> HiveCheckpoint<Schema>?

    public init<S: HiveCheckpointStore>(_ store: S) where S.Schema == Schema {
        self._save = store.save
        self._loadLatest = store.loadLatest
    }

    public func save(_ checkpoint: HiveCheckpoint<Schema>) async throws {
        try await _save(checkpoint)
    }

    public func loadLatest(threadID: HiveThreadID) async throws -> HiveCheckpoint<Schema>? {
        try await _loadLatest(threadID)
    }
}
