import CryptoKit
import Foundation

enum HiveVersioning {
    static func schemaVersion<Schema: HiveSchema>(registry: HiveSchemaRegistry<Schema>) -> String {
        var bytes = Data()
        bytes.append(contentsOf: [0x48, 0x53, 0x56, 0x31]) // HSV1
        bytes.append(0x43)
        appendUInt32BE(UInt32(registry.sortedChannelSpecs.count), to: &bytes)

        for spec in registry.sortedChannelSpecs {
            let idData = Data(spec.id.rawValue.utf8)
            appendUInt32BE(UInt32(idData.count), to: &bytes)
            bytes.append(idData)
            bytes.append(scopeByte(spec.scope))
            bytes.append(persistenceByte(spec.persistence))
            bytes.append(updatePolicyByte(spec.updatePolicy))
            let codecID = spec.codecID ?? ""
            let codecData = Data(codecID.utf8)
            appendUInt32BE(UInt32(codecData.count), to: &bytes)
            bytes.append(codecData)
        }

        return sha256Hex(bytes)
    }

    static func graphVersion<Schema: HiveSchema>(
        start: [HiveNodeID],
        nodesByID: [HiveNodeID: HiveCompiledNode<Schema>],
        routerFrom: [HiveNodeID],
        staticEdges: [(from: HiveNodeID, to: HiveNodeID)],
        joinEdges: [(parents: [HiveNodeID], target: HiveNodeID)],
        outputProjection: HiveOutputProjection
    ) -> String {
        var bytes = Data()
        bytes.append(contentsOf: [0x48, 0x47, 0x56, 0x31]) // HGV1

        bytes.append(0x53) // S
        appendUInt32BE(UInt32(start.count), to: &bytes)
        for id in start {
            appendID(id.rawValue, to: &bytes)
        }

        bytes.append(0x4E) // N
        let sortedNodes = nodesByID.keys.sorted { HiveOrdering.lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        appendUInt32BE(UInt32(sortedNodes.count), to: &bytes)
        for id in sortedNodes {
            appendID(id.rawValue, to: &bytes)
        }

        bytes.append(0x52) // R
        let sortedRouters = routerFrom.sorted { HiveOrdering.lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
        appendUInt32BE(UInt32(sortedRouters.count), to: &bytes)
        for id in sortedRouters {
            appendID(id.rawValue, to: &bytes)
        }

        bytes.append(0x45) // E
        appendUInt32BE(UInt32(staticEdges.count), to: &bytes)
        for edge in staticEdges {
            appendID(edge.from.rawValue, to: &bytes)
            appendID(edge.to.rawValue, to: &bytes)
        }

        bytes.append(0x4A) // J
        appendUInt32BE(UInt32(joinEdges.count), to: &bytes)
        for edge in joinEdges {
            appendID(edge.target.rawValue, to: &bytes)
            let parents = edge.parents.sorted { HiveOrdering.lexicographicallyPrecedes($0.rawValue, $1.rawValue) }
            appendUInt32BE(UInt32(parents.count), to: &bytes)
            for parent in parents {
                appendID(parent.rawValue, to: &bytes)
            }
        }

        bytes.append(0x4F) // O
        switch outputProjection {
        case .fullStore:
            bytes.append(0)
        case .channels(let ids):
            bytes.append(1)
            let normalized = HiveOrdering.uniqueChannelIDs(ids)
            appendUInt32BE(UInt32(normalized.count), to: &bytes)
            for id in normalized {
                appendID(id.rawValue, to: &bytes)
            }
        }

        return sha256Hex(bytes)
    }

    private static func appendID(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt32BE(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func scopeByte(_ scope: HiveChannelScope) -> UInt8 {
        switch scope {
        case .global: return 0
        case .taskLocal: return 1
        }
    }

    private static func persistenceByte(_ persistence: HiveChannelPersistence) -> UInt8 {
        switch persistence {
        case .checkpointed: return 0
        case .untracked: return 1
        }
    }

    private static func updatePolicyByte(_ policy: HiveUpdatePolicy) -> UInt8 {
        switch policy {
        case .single: return 0
        case .multi: return 1
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
