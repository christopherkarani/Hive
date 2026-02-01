Prompt:
Create minimal module stubs so all targets compile and the umbrella module re-exports the full stack.

Goal:
Ensure each module compiles with a minimal public surface, and HiveCore exports at least one public symbol.

Task BreakDown:
1. Create Sources layout for HiveCore, HiveCheckpointWax, HiveConduit, HiveSwiftAgents, Hive (umbrella).
2. Add a minimal public symbol to HiveCore (e.g., enum HiveCoreVersion).
3. Add minimal public symbols for other targets to confirm linking.
4. Add Hive umbrella file that re-exports HiveCore, HiveSwiftAgents, HiveConduit, HiveCheckpointWax.
5. Keep code minimal, no runtime implementation.
