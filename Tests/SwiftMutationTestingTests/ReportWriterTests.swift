import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Report output")
struct ReportWriterTests {
    @Test("writes canonical JSON and Markdown")
    func writesReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = MutantRecord(id: "fixture-id", operatorID: .boolean, source: "Sources/Example.swift", line: 2, column: 8, original: "true", replacement: "false", status: .noCoverage, activated: false)
        let report = MutationReport(
            scope: .init(sources: [record.source], tests: [], allTests: true),
            mutants: [record],
            timings: .init(baselineSeconds: 2.5, schemaBuildSeconds: 3.25)
        )
        try MutationReportWriter.write(report, to: directory,
            runDetails: .init(testTarget: "FixtureTests", baselineTestCount: 50, mutantTestRunCount: 7, totalDurationSeconds: 174,
                requestedWorkerCount: 2, activeWorkerCount: 2, baselineRunCount: 2, baselineTestExecutionCount: 100, simulatorSetupSeconds: 3.5))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stryker.json").path))
        let canonicalData = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        let canonical = try #require(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        let timings = try #require(canonical["timings"] as? [String: Double])
        #expect(timings["baselineSeconds"] == 2.5)
        let execution = try #require(canonical["execution"] as? [String: Any])
        #expect(execution["activeWorkerCount"] as? Int == 2)
        #expect(execution["mutantTestRunCount"] as? Int == 7)
        #expect(execution["baselineTestExecutionCount"] as? Int == 100)
        #expect(execution["totalDurationSeconds"] as? Double == 174)
        let markdown = try String(contentsOf: directory.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(markdown.contains("| Schema build | 3.25 |"))
        #expect(markdown.contains("**Baseline tests per worker:** 50"))
        #expect(markdown.contains("**Baseline runs:** 2 (100 reported tests across all baseline runs)"))
        #expect(markdown.contains("**Workers:** 2 active / 2 requested"))
        #expect(markdown.contains("**Total time:** 2m 54s"))
    }

    @Test("respects requested report formats")
    func selectedFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = MutationReport(scope: .init(sources: [], tests: [], allTests: true), mutants: [])
        try MutationReportWriter.write(report, to: directory, formats: ["json"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stryker.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.md").path))
    }

    @Test("does not report zero observed test files when Xcode omits test file paths")
    func hidesUnavailableTestFileCounts() {
        let source = "Sources/Example.swift"
        let report = MutationReport(
            scope: .init(sources: [source], tests: ["FixtureTests/ExampleTests/testRule()"], allTests: false),
            mutants: [MutantRecord(id: "mutant", operatorID: .boolean, source: source, line: 2, original: "true", replacement: "false", status: .killed)]
        )
        let details = MutationRunSummaryDetails(
            mutantTestRuns: [MutantTestRunDetails(
                mutantId: "mutant",
                source: source,
                reportedCaseCount: 1,
                testCases: [MutationTestCaseDetails(identifier: "FixtureTests/ExampleTests/testRule()", name: "testRule", testFile: nil, lineNumber: nil, result: "passed")]
            )]
        )

        let markdown = MutationReportWriter.markdown(report, runDetails: details)

        #expect(markdown.contains("Unique unit tests observed"))
        #expect(!markdown.contains("Test files observed"))
        #expect(markdown.contains("| `Sources/Example.swift` | 1 | 1 | 1 | 1 |"))
    }
}
