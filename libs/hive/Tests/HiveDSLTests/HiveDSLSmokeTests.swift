import Testing
import HiveDSL

@Test("HiveDSL module loads")
func hiveDSLModuleLoads() {
    #expect(HiveDSLVersion.string == "0.0.0")
}

@Test("HiveDSL exposes HiveCore symbols")
func hiveDSLExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}

