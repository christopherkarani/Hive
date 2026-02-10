import Testing
import HiveMacros

@Test("HiveMacros module loads")
func hiveMacrosModuleLoads() {
    #expect(HiveMacrosVersion.string == "0.0.0")
}

@Test("HiveMacros exposes HiveCore symbols")
func hiveMacrosExposesHiveCoreSymbols() {
    let id = HiveChannelID("smoke")
    #expect(id.rawValue == "smoke")
}

