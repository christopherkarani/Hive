import SwiftSyntax
import SwiftSyntaxMacros

public struct TaskLocalChannelMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Stub implementation; populated in later phases.
        []
    }
}

