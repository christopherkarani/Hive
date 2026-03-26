import Testing
import HiveConduit

@Test("HiveConduit module loads")
func hiveConduitModuleLoads() {
    #expect(HiveVersion.conduit == "0.0.0")
}

@Test("HiveConduit exposes HiveCore symbols")
func hiveConduitExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}
