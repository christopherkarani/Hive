import Foundation
import Testing
@testable import HiveCore

private struct IntTextCodec: HiveCodec {
    enum CodecError: Error { case invalidUTF8; case invalidInteger }

    let id: String = "int.text"

    func encode(_ value: Int) throws -> Data {
        Data(String(value).utf8)
    }

    func decode(_ data: Data) throws -> Int {
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodecError.invalidUTF8
        }
        guard let value = Int(string) else {
            throw CodecError.invalidInteger
        }
        return value
    }
}

private enum TestSchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<TestSchema>] { [] }
}

@Test("HiveCodec round-trips canonical bytes")
func hiveCodecRoundTrip() throws {
    let codec = IntTextCodec()
    let data = try codec.encode(42)
    #expect(String(data: data, encoding: .utf8) == "42")
    #expect(try codec.decode(data) == 42)
}

@Test("AnyHiveChannelSpec preserves metadata")
func anyHiveChannelSpecMetadata() throws {
    let key = HiveChannelKey<TestSchema, Int>(HiveChannelID("count"))
    let reducer = HiveReducer<Int> { current, update in current + update }
    let codec = HiveAnyCodec(IntTextCodec())
    let spec = HiveChannelSpec(
        key: key,
        scope: .global,
        reducer: reducer,
        updatePolicy: .multi,
        initial: { 0 },
        codec: codec,
        persistence: .checkpointed
    )

    let erased = AnyHiveChannelSpec(spec)
    #expect(erased.id == key.id)
    #expect(erased.scope == .global)
    #expect(erased.persistence == .checkpointed)
    #expect(erased.updatePolicy == .multi)
    #expect(erased.valueTypeID == String(reflecting: Int.self))
    #expect(erased.codecID == "int.text")
}

@Test("AnyHiveWrite preserves channel ID and value")
func anyHiveWritePreservesChannelIDAndValue() throws {
    let globalKey = HiveChannelKey<TestSchema, String>(HiveChannelID("message"))
    let globalWrite = AnyHiveWrite(globalKey, "hello")
    #expect(globalWrite.channelID.rawValue == "message")
    #expect(globalWrite.value as? String == "hello")

    let taskLocalKey = HiveChannelKey<TestSchema, Int>(HiveChannelID("localCounter"))
    let localWrite = AnyHiveWrite(taskLocalKey, 7)
    #expect(localWrite.channelID.rawValue == "localCounter")
    #expect(localWrite.value as? Int == 7)
}

@Test("HiveSchemaRegistry rejects duplicate channel IDs")
func hiveSchemaRegistryRejectsDuplicates() throws {
    let key = HiveChannelKey<TestSchema, Int>(HiveChannelID("dup"))
    let reducer = HiveReducer<Int> { current, update in current + update }
    let specA = HiveChannelSpec(
        key: key,
        scope: .global,
        reducer: reducer,
        initial: { 0 },
        persistence: .checkpointed
    )
    let specB = HiveChannelSpec(
        key: key,
        scope: .global,
        reducer: reducer,
        initial: { 1 },
        persistence: .checkpointed
    )

    do {
        _ = try HiveSchemaRegistry<TestSchema>(channelSpecs: [AnyHiveChannelSpec(specA), AnyHiveChannelSpec(specB)])
        #expect(Bool(false))
    } catch let error as HiveCompilationError {
        switch error {
        case .duplicateChannelID(let id):
            #expect(id.rawValue == "dup")
        default:
            #expect(Bool(false))
        }
    }
}

@Test("HiveSchemaRegistry rejects taskLocal untracked channels")
func hiveSchemaRegistryRejectsInvalidTaskLocalUntracked() throws {
    let key = HiveChannelKey<TestSchema, Int>(HiveChannelID("local"))
    let reducer = HiveReducer<Int> { current, update in current + update }
    let spec = HiveChannelSpec(
        key: key,
        scope: .taskLocal,
        reducer: reducer,
        initial: { 0 },
        persistence: .untracked
    )

    do {
        _ = try HiveSchemaRegistry<TestSchema>(channelSpecs: [AnyHiveChannelSpec(spec)])
        #expect(Bool(false))
    } catch let error as HiveCompilationError {
        switch error {
        case .invalidTaskLocalUntracked(let id):
            #expect(id.rawValue == "local")
        default:
            #expect(Bool(false))
        }
    }
}

@Test("HiveSchemaRegistry selects smallest missing required codec ID")
func hiveSchemaRegistryMissingCodecSelection() throws {
    let reducer = HiveReducer<Int> { current, update in current + update }
    let codec = HiveAnyCodec(IntTextCodec())

    let aKey = HiveChannelKey<TestSchema, Int>(HiveChannelID("a"))
    let bKey = HiveChannelKey<TestSchema, Int>(HiveChannelID("b"))
    let cKey = HiveChannelKey<TestSchema, Int>(HiveChannelID("c"))

    let specA = HiveChannelSpec(
        key: aKey,
        scope: .global,
        reducer: reducer,
        initial: { 0 },
        codec: nil,
        persistence: .checkpointed
    )
    let specB = HiveChannelSpec(
        key: bKey,
        scope: .taskLocal,
        reducer: reducer,
        initial: { 0 },
        codec: nil,
        persistence: .checkpointed
    )
    let specC = HiveChannelSpec(
        key: cKey,
        scope: .global,
        reducer: reducer,
        initial: { 0 },
        codec: codec,
        persistence: .checkpointed
    )

    let registry = try HiveSchemaRegistry<TestSchema>(channelSpecs: [
        AnyHiveChannelSpec(specC),
        AnyHiveChannelSpec(specB),
        AnyHiveChannelSpec(specA),
    ])
    #expect(registry.firstMissingRequiredCodecID()?.rawValue == "a")
}

@Test("HiveSchemaRegistry ignores missing codec for untracked global channels")
func hiveSchemaRegistryIgnoresUntrackedGlobalMissingCodec() throws {
    let reducer = HiveReducer<Int> { current, update in current + update }
    let key = HiveChannelKey<TestSchema, Int>(HiveChannelID("untracked"))
    let spec = HiveChannelSpec(
        key: key,
        scope: .global,
        reducer: reducer,
        initial: { 0 },
        codec: nil,
        persistence: .untracked
    )
    let registry = try HiveSchemaRegistry<TestSchema>(channelSpecs: [AnyHiveChannelSpec(spec)])
    #expect(registry.firstMissingRequiredCodecID() == nil)
}

private enum TypeRegistrySchema: HiveSchema {
    static var channelSpecs: [AnyHiveChannelSpec<TypeRegistrySchema>] {
        let reducer = HiveReducer<Int> { current, update in current + update }
        let key = HiveChannelKey<TypeRegistrySchema, Int>(HiveChannelID("count"))
        let spec = HiveChannelSpec(
            key: key,
            scope: .global,
            reducer: reducer,
            initial: { 0 },
            persistence: .checkpointed
        )
        return [AnyHiveChannelSpec(spec)]
    }
}

@Test("HiveChannelTypeRegistry returns typed values")
func hiveChannelTypeRegistryCastsTypedValue() throws {
    let registry = try HiveSchemaRegistry<TypeRegistrySchema>()
    let typeRegistry = HiveChannelTypeRegistry(registry)
    let key = HiveChannelKey<TypeRegistrySchema, Int>(HiveChannelID("count"))
    let value = try typeRegistry.cast(12, for: key)
    #expect(value == 12)
}
