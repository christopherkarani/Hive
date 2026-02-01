import Testing
@testable import HiveCore

private final class CallRecorder: @unchecked Sendable {
    private(set) var calls: [String] = []

    func record(_ key: String) {
        calls.append(key)
    }
}

private struct KeyedValue: Sendable {
    let key: String
}

@Test("HiveReducer.append preserves element order")
func hiveReducerAppendPreservesOrder() throws {
    let reducer: HiveReducer<[Int]> = .append()
    let result = try reducer.reduce(current: [1, 2], update: [3, 4])
    #expect(result == [1, 2, 3, 4])
}

@Test("HiveReducer.appendNonNil drops nils and preserves order")
func hiveReducerAppendNonNilPreservesOrder() throws {
    let reducer: HiveReducer<[Int]?> = .appendNonNil()

    #expect(try reducer.reduce(current: nil, update: nil) == nil)
    #expect(try reducer.reduce(current: nil, update: [1, 2]) == [1, 2])
    #expect(try reducer.reduce(current: [3], update: nil) == [3])
    #expect(try reducer.reduce(current: [3], update: [4, 5]) == [3, 4, 5])
}

@Test("HiveReducer.dictionaryMerge processes update keys in UTF-8 order")
func hiveReducerDictionaryMergeOrdersKeys() throws {
    let recorder = CallRecorder()
    let valueReducer = HiveReducer<KeyedValue> { _, update in
        recorder.record(update.key)
        return update
    }
    let reducer: HiveReducer<[String: KeyedValue]> = .dictionaryMerge(valueReducer: valueReducer)

    let update: [String: KeyedValue] = [
        "b": KeyedValue(key: "b"),
        "é": KeyedValue(key: "é"),
        "a": KeyedValue(key: "a"),
        "c": KeyedValue(key: "c"),
    ]
    let current: [String: KeyedValue] = [
        "a": KeyedValue(key: "a"),
        "b": KeyedValue(key: "b"),
        "é": KeyedValue(key: "é"),
        "c": KeyedValue(key: "c"),
    ]

    _ = try reducer.reduce(current: current, update: update)

    let expected = update.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    #expect(recorder.calls == expected)
}
