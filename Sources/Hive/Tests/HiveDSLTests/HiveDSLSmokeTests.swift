import Testing
import HiveDSL

@Suite("HiveDSLSmoke", .serialized)
struct HiveDSLSmokeTests {
    @Test("HiveDSL module loads")
    func hiveDSLModuleLoads() {
        #expect(HiveVersion.dsl == "0.0.0")
    }

    @Test("HiveDSL exposes HiveCore symbols")
    func hiveDSLExposesHiveCoreSymbols() {
        let id = HiveChannelID("smoke")
        #expect(id.rawValue == "smoke")
    }
}
