/// Declares optional macros for reducing Hive boilerplate.
///
/// These macros are implemented by the `HiveMacrosImpl` compiler plugin target.

@attached(member, names: arbitrary)
@attached(extension, names: arbitrary)
public macro HiveSchema() = #externalMacro(module: "HiveMacrosImpl", type: "HiveSchemaMacro")

@attached(peer, names: arbitrary)
public macro Channel(
    scope: String = "global",
    reducer: String,
    updatePolicy: String = "single",
    persistence: String,
    codec: String? = nil
) = #externalMacro(module: "HiveMacrosImpl", type: "ChannelMacro")

@attached(peer, names: arbitrary)
public macro TaskLocalChannel(
    reducer: String,
    updatePolicy: String = "single",
    persistence: String,
    codec: String? = nil
) = #externalMacro(module: "HiveMacrosImpl", type: "TaskLocalChannelMacro")

@attached(member, names: arbitrary)
@attached(extension, names: arbitrary)
public macro WorkflowBlueprint() = #externalMacro(module: "HiveMacrosImpl", type: "WorkflowBlueprintMacro")
