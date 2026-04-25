import Testing
import Hive

@Test("Hive umbrella module loads")
func hiveUmbrellaModuleLoads() {
    #expect(HiveVersion.string == "0.0.0")
}

@Test("Hive umbrella re-exports submodules")
func hiveUmbrellaReexportsSubmodules() {
    _ = HiveVersion.self
    enum EmptySchema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
    }
    _ = HiveGraphBuilder<EmptySchema>.self
}
