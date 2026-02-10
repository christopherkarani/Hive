import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct HiveMacrosImplPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        HiveSchemaMacro.self,
        ChannelMacro.self,
        TaskLocalChannelMacro.self,
        WorkflowBlueprintMacro.self,
    ]
}

