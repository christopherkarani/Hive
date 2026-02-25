import Foundation
import Testing
@testable import HiveCore

@Suite("Hive transcript replay compatibility fixtures")
struct HiveTranscriptReplayCompatibilityFixtureTests {
    private func loadFixture(named resourceName: String) throws -> HiveEventTranscript {
        let candidateSubdirectories: [String?] = [
            nil,
            "Runtime/Fixtures",
            "Fixtures",
            "Runtime_Fixtures",
        ]

        let url = candidateSubdirectories.compactMap { subdirectory in
            Bundle.module.url(
                forResource: resourceName,
                withExtension: "json",
                subdirectory: subdirectory
            )
        }.first

        let resolvedURL = try #require(url)
        let data = try Data(contentsOf: resolvedURL)
        return try JSONDecoder().decode(HiveEventTranscript.self, from: data)
    }

    @Test("HES0 fixture is typed incompatible with current replay schema")
    func hes0FixtureIncompatibleWithCurrent() throws {
        let transcript = try loadFixture(named: "transcript-hes0")
        #expect(transcript.schemaVersion == .v0)

        do {
            try transcript.validateReplayCompatibility(expected: .current)
            #expect(Bool(false))
        } catch let error as HiveEventReplayCompatibilityError {
            guard case .incompatibleSchemaVersion(let expected, let found) = error else {
                #expect(Bool(false))
                return
            }
            #expect(expected == .current)
            #expect(found == .v0)
        }
    }

    @Test("HES1 fixture is replay-compatible with current schema")
    func hes1FixtureCompatibleWithCurrent() throws {
        let transcript = try loadFixture(named: "transcript-hes1")
        #expect(transcript.schemaVersion == .v1)
        try transcript.validateReplayCompatibility(expected: .current)
    }

    @Test("Fixture diff reports schema mismatch key path deterministically")
    func fixtureSchemaDiffIsDeterministic() throws {
        let legacy = try loadFixture(named: "transcript-hes0")
        let current = try loadFixture(named: "transcript-hes1")

        let diff = legacy.firstDiff(comparedTo: current)
        #expect(diff?.eventIndex == 0)
        #expect(diff?.keyPath == "schemaVersion")
        #expect(diff?.lhs == "HES0")
        #expect(diff?.rhs == "HES1")
    }
}
