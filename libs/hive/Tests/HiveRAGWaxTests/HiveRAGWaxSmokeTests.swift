import Testing
import HiveRAGWax

@Test("HiveRAGWax module loads")
func hiveRAGWaxModuleLoads() {
    #expect(HiveRAGWaxVersion.string == "0.0.0")
}

@Test("HiveRAGWax exposes HiveCore symbols")
func hiveRAGWaxExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}

