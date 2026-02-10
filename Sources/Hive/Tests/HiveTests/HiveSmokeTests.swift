import Testing
import Hive

@Test("Hive umbrella module loads")
func hiveUmbrellaModuleLoads() {
    #expect(HiveVersion.string == "0.0.0")
}

@Test("Hive umbrella re-exports submodules")
func hiveUmbrellaReexportsSubmodules() {
    _ = HiveCoreVersion.self
    _ = HiveConduitVersion.self
    _ = HiveCheckpointWaxVersion.self
    enum EmptySchema: HiveSchema {
        static var channelSpecs: [AnyHiveChannelSpec<Self>] { [] }
    }
    _ = Workflow<EmptySchema>.self
}
