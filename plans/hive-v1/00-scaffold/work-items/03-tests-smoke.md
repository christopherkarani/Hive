Prompt:
Add Swift Testing smoke tests for each target (including umbrella).

Goal:
Prove test discovery and linking work for all targets under swift test.

Task BreakDown:
1. Create Tests layout for HiveCoreTests, HiveCheckpointWaxTests, HiveConduitTests, HiveTests.
2. Add one Swift Testing test per target that imports the module and asserts a trivial condition.
3. For the Hive umbrella, verify re-exported symbols are visible.
