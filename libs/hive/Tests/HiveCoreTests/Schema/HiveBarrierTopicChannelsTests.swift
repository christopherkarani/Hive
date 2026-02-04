import Testing
@testable import HiveCore

@Test("Barrier reducer accumulates markSeen updates and normalizes to state")
func testBarrierReducer_AccumulatesAndNormalizesToState() throws {
    let reducer = HiveReducer<HiveBarrierChannelValue>.barrier()

    let barrier = HiveBarrierKey("b1")
    let a = HiveNodeID("A")
    let b = HiveNodeID("B")

    var value: HiveBarrierChannelValue = .state(.empty)

    value = try reducer.reduce(
        current: value,
        update: .update(.markSeen(barrier: barrier, producer: a, token: HiveBarrierToken("t1")))
    )
    value = try reducer.reduce(
        current: value,
        update: .update(.markSeen(barrier: barrier, producer: b, token: HiveBarrierToken("t2")))
    )

    let state = try #require(value.stateValue)
    #expect(state.tokens(for: barrier).count == 2)
    #expect(state.token(for: barrier, producer: a) == HiveBarrierToken("t1"))
    #expect(state.token(for: barrier, producer: b) == HiveBarrierToken("t2"))
}

@Test("Barrier consume clears only when available for expected producers")
func testBarrierReducer_ConsumeOnlyWhenAvailable() throws {
    let reducer = HiveReducer<HiveBarrierChannelValue>.barrier()

    let barrier = HiveBarrierKey("b1")
    let a = HiveNodeID("A")
    let b = HiveNodeID("B")

    var value: HiveBarrierChannelValue = .state(.empty)

    value = try reducer.reduce(
        current: value,
        update: .update(.markSeen(barrier: barrier, producer: a, token: HiveBarrierToken("t1")))
    )

    // Not available yet (missing B) → consume is a no-op.
    value = try reducer.reduce(
        current: value,
        update: .update(.consume(barrier: barrier, expectedProducers: [a, b]))
    )
    #expect(try #require(value.stateValue).tokens(for: barrier).count == 1)

    value = try reducer.reduce(
        current: value,
        update: .update(.markSeen(barrier: barrier, producer: b, token: HiveBarrierToken("t2")))
    )

    // Now available → consume clears.
    value = try reducer.reduce(
        current: value,
        update: .update(.consume(barrier: barrier, expectedProducers: [a, b]))
    )
    #expect(try #require(value.stateValue).tokens(for: barrier).isEmpty)
}

@Test("Topic reducer publishes deterministically and applies bounded eviction")
func testTopicReducer_PublishAndEvict() throws {
    let reducer = HiveReducer<HiveTopicChannelValue<Int>>.topicAppendOnly(maxValuesPerTopic: 2)

    let topic = HiveTopicKey("t")
    var value: HiveTopicChannelValue<Int> = .state(.empty)

    value = try reducer.reduce(current: value, update: .update(.publish(topic: topic, value: 1)))
    value = try reducer.reduce(current: value, update: .update(.publish(topic: topic, value: 2)))
    value = try reducer.reduce(current: value, update: .update(.publish(topic: topic, value: 3)))

    let state = try #require(value.stateValue)
    #expect(state.values(for: topic) == [2, 3])
}

@Test("Topic reducer clear removes all values for the topic")
func testTopicReducer_Clear() throws {
    let reducer = HiveReducer<HiveTopicChannelValue<Int>>.topicAppendOnly(maxValuesPerTopic: 10)

    let topic = HiveTopicKey("t")
    var value: HiveTopicChannelValue<Int> = .state(.empty)

    value = try reducer.reduce(current: value, update: .update(.publish(topic: topic, value: 1)))
    value = try reducer.reduce(current: value, update: .update(.clear(topic: topic)))

    let state = try #require(value.stateValue)
    #expect(state.values(for: topic).isEmpty)
}

