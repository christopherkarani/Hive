import Testing
import HiveCheckpointWax

@Suite("HiveCheckpointWaxSmoke", .serialized)
struct HiveCheckpointWaxSmokeTests {
@Test("HiveCheckpointWax module loads")
func hiveCheckpointWaxModuleLoads() {
    #expect(HiveCheckpointWaxVersion.string == "0.0.0")
}

@Test("HiveCheckpointWax exposes HiveCore symbols")
func hiveCheckpointWaxExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}
}
