import Foundation
import Testing
@testable import HiveCore

private struct FailingCodec: HiveCodec {
    enum CodecError: Error { case fail }

    let id: String = "fail.v1"

    func encode(_ value: Int) throws -> Data {
        throw CodecError.fail
    }

    func decode(_ data: Data) throws -> Int {
        0
    }
}

private enum EmptyFingerprintSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<EmptyFingerprintSchema>] { [] }
}

private enum FailingFingerprintSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<FailingFingerprintSchema>] {
        let reducer = HiveReducer<Int> { current, update in current + update }
        let codec = HiveAnyCodec(FailingCodec())

        let keyB = HiveChannelKey<FailingFingerprintSchema, Int>(HiveChannelID("b"))
        let keyA = HiveChannelKey<FailingFingerprintSchema, Int>(HiveChannelID("a"))

        let specB = HiveChannelSpec(
            key: keyB,
            scope: .taskLocal,
            reducer: reducer,
            initial: { 2 },
            codec: codec,
            persistence: .checkpointed
        )
        let specA = HiveChannelSpec(
            key: keyA,
            scope: .taskLocal,
            reducer: reducer,
            initial: { 1 },
            codec: codec,
            persistence: .checkpointed
        )

        return [AnyHiveChannelSpec(specB), AnyHiveChannelSpec(specA)]
    }
}

@Test("Task-local fingerprint matches empty golden")
func testTaskLocalFingerprint_EmptyGolden() throws {
    let registry = try HiveSchemaRegistry<EmptyFingerprintSchema>()
    let cache = HiveInitialCache(registry: registry)
    let overlay = HiveTaskLocalStore<EmptyFingerprintSchema>.empty

    let digest = try HiveTaskLocalFingerprint.digest(
        registry: registry,
        initialCache: cache,
        overlay: overlay
    )

    #expect(digest.hexLowercased == "3b54d1bf22aea64fa72d74e8bca1e504ea5f40f832e6bbf952ba79015becff2f")
}

@Test("Task-local fingerprint encode failure is deterministic")
func testTaskLocalFingerprintEncodeFailure_Deterministic() throws {
    let registry = try HiveSchemaRegistry<FailingFingerprintSchema>()
    let cache = HiveInitialCache(registry: registry)
    let overlay = HiveTaskLocalStore<FailingFingerprintSchema>.empty

    do {
        _ = try HiveTaskLocalFingerprint.digest(
            registry: registry,
            initialCache: cache,
            overlay: overlay
        )
        #expect(Bool(false))
    } catch let error as HiveRuntimeError {
        switch error {
        case .taskLocalFingerprintEncodeFailed(let channelID, _):
            #expect(channelID.rawValue == "a")
        default:
            #expect(Bool(false))
        }
    }
}

private extension Data {
    var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
