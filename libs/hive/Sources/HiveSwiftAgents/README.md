# HiveSwiftAgents

SwiftAgents integration for Hive tool calling.

Note: `HiveSwiftAgents` is shipped by the SwiftAgents package. Add SwiftAgents as a dependency and import `HiveSwiftAgents`.

## Usage
```swift
import HiveCore
import HiveSwiftAgents
import SwiftAgents

let tools: [any AnyJSONTool] = [weatherTool, calendarTool]
let registry = try SwiftAgentsToolRegistry(tools: tools)

let environment = HiveEnvironment<MySchema>(
    context: appContext,
    clock: appClock,
    logger: appLogger,
    model: AnyHiveModelClient(model),
    tools: AnyHiveToolRegistry(registry)
)
```

If you already have a SwiftAgents `ToolRegistry`, use `SwiftAgentsToolRegistry.fromRegistry(_:)` to bridge it.

## Example
- `../../Tests/HiveSwiftAgentsTests/HiveSwiftAgentsSmokeTests.swift`
