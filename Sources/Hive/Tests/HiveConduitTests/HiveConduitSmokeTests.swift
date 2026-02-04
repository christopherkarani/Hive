import Testing
import HiveConduit

@Test("HiveConduit module loads")
func hiveConduitModuleLoads() {
    #expect(HiveConduitVersion.string == "0.0.0")
}

@Test("HiveConduit exposes HiveCore symbols")
func hiveConduitExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}
