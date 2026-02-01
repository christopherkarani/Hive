import Testing
import HiveSwiftAgents

@Test("HiveSwiftAgents module loads")
func hiveSwiftAgentsModuleLoads() {
    #expect(HiveSwiftAgentsVersion.string == "0.0.0")
}

@Test("HiveSwiftAgents exposes HiveCore symbols")
func hiveSwiftAgentsExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}
