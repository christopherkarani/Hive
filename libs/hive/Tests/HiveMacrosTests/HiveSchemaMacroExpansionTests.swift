import XCTest
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport

#if canImport(HiveMacrosImpl)
import HiveMacrosImpl
#endif

final class HiveSchemaMacroExpansionTests: XCTestCase {
    func testHiveSchemaMacroGeneratesChannelSpecs() throws {
    #if canImport(HiveMacrosImpl)
    let hiveMacros: [String: Macro.Type] = [
        "HiveSchema": HiveSchemaMacro.self,
        "Channel": ChannelMacro.self,
        "TaskLocalChannel": TaskLocalChannelMacro.self
    ]
    assertMacroExpansion(
        """
        @HiveSchema
        enum Demo: HiveSchema {
            @Channel(reducer: "lastWriteWins()", persistence: "untracked")
            static var _answer: String = ""

            @TaskLocalChannel(reducer: "append()", persistence: "checkpointed")
            static var _logs: [String] = []
        }
        """,
        expandedSource: """
        enum Demo: HiveSchema {
            static var _answer: String = ""
            static var _logs: [String] = []

            static let answer = HiveChannelKey<Self, String>(HiveChannelID("answer"))

            static let logs = HiveChannelKey<Self, [String]>(HiveChannelID("logs"))

            static var channelSpecs: [AnyHiveChannelSpec<Self>] {
                [
                    AnyHiveChannelSpec(
                        HiveChannelSpec(
                            key: Self.answer,
                            scope: .global,
                            reducer: .lastWriteWins(),
                            updatePolicy: .single,
                            initial: {
                                ""
                            },
                            codec: nil,
                            persistence: .untracked
                        )
                    ),
                    AnyHiveChannelSpec(
                        HiveChannelSpec(
                            key: Self.logs,
                            scope: .taskLocal,
                            reducer: .append(),
                            updatePolicy: .single,
                            initial: {
                                []
                            },
                            codec: HiveAnyCodec(HiveJSONCodec<[String]>()),
                            persistence: .checkpointed
                        )
                    )
                ]
            }
        }
        """,
        macros: hiveMacros
    )
    #else
    XCTFail("HiveMacrosImpl not available")
    #endif
    }

    func testTaskLocalUntrackedChannelDiagnostic() throws {
    #if canImport(HiveMacrosImpl)
    let hiveMacros: [String: Macro.Type] = [
        "HiveSchema": HiveSchemaMacro.self,
        "Channel": ChannelMacro.self,
        "TaskLocalChannel": TaskLocalChannelMacro.self
    ]
    assertMacroExpansion(
        """
        @HiveSchema
        enum BadSchema: HiveSchema {
            @TaskLocalChannel(reducer: "lastWriteWins()", persistence: "untracked")
            static var _bad: Int = 0
        }
        """,
        expandedSource: """
        enum BadSchema: HiveSchema {
            static var _bad: Int = 0

            static let bad = HiveChannelKey<Self, Int>(HiveChannelID("bad"))

            static var channelSpecs: [AnyHiveChannelSpec<Self>] {
                [
                    AnyHiveChannelSpec(
                        HiveChannelSpec(
                            key: Self.bad,
                            scope: .taskLocal,
                            reducer: .lastWriteWins(),
                            updatePolicy: .single,
                            initial: {
                                0
                            },
                            codec: HiveAnyCodec(HiveJSONCodec<Int>()),
                            persistence: .untracked
                        )
                    )
                ]
            }
        }
        """,
        diagnostics: [
            DiagnosticSpec(message: "Task-local channels must be checkpointed.", line: 3, column: 5, severity: .error)
        ],
        macros: hiveMacros
    )
    #else
    XCTFail("HiveMacrosImpl not available")
    #endif
    }

    func testCodecOverridePassesThroughToChannelSpecs() throws {
    #if canImport(HiveMacrosImpl)
    let hiveMacros: [String: Macro.Type] = [
        "HiveSchema": HiveSchemaMacro.self,
        "Channel": ChannelMacro.self,
        "TaskLocalChannel": TaskLocalChannelMacro.self
    ]
    assertMacroExpansion(
        """
        struct NonCodable {}

        struct NonCodableCodec: HiveCodec {
            let id: String = "noncodable.v1"
            func encode(_ value: NonCodable) throws -> Data { Data() }
            func decode(_ data: Data) throws -> NonCodable { NonCodable() }
        }

        @HiveSchema
        enum BadSchema: HiveSchema {
            @Channel(reducer: "lastWriteWins()", persistence: "checkpointed", codec: "NonCodableCodec()")
            static var _bad: NonCodable = NonCodable()
        }
        """,
        expandedSource: """
        struct NonCodable {}

        struct NonCodableCodec: HiveCodec {
            let id: String = "noncodable.v1"
            func encode(_ value: NonCodable) throws -> Data { Data() }
            func decode(_ data: Data) throws -> NonCodable { NonCodable() }
        }
        enum BadSchema: HiveSchema {
            static var _bad: NonCodable = NonCodable()

            static let bad = HiveChannelKey<Self, NonCodable>(HiveChannelID("bad"))

            static var channelSpecs: [AnyHiveChannelSpec<Self>] {
                [
                    AnyHiveChannelSpec(
                        HiveChannelSpec(
                            key: Self.bad,
                            scope: .global,
                            reducer: .lastWriteWins(),
                            updatePolicy: .single,
                            initial: {
                                NonCodable()
                            },
                            codec: HiveAnyCodec(NonCodableCodec()),
                            persistence: .checkpointed
                        )
                    )
                ]
            }
        }
        """,
        macros: hiveMacros
    )
    #else
    XCTFail("HiveMacrosImpl not available")
    #endif
    }
}
