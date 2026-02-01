Prompt:
Create the SwiftPM package manifest for libs/hive with the required targets and test targets.

Goal:
Define a Swift 6.2-compatible Package.swift that declares Hive libraries, including an umbrella product for the full stack, with correct module boundaries.

Task BreakDown:
1. Set tools version for Swift 6.2.
2. Define products: Hive (umbrella), HiveCore, HiveCheckpointWax, HiveConduit, HiveSwiftAgents.
3. Define targets and test targets for each module.
4. Add dependency placeholders or local path dependencies for Wax, Conduit, SwiftAgents.
5. Ensure HiveCore has no direct imports on Wax/Conduit/SwiftAgents (enforced via target deps).
6. Set deployment targets to iOS 17.0 and macOS 14.0.
