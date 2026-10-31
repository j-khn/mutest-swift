import Foundation
import Testing
@testable import SwiftMutationTesting
import MutationTestingSpec

@Suite("Report output")
struct ReportWriterTests {
    @Test("writes canonical JSON, Markdown, and Stryker schema output")
    func writesReports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = MutantRecord(id: "fixture-id", operatorID: .boolean, source: "Sources/Example.swift", line: 2, column: 8, original: "true", replacement: "false", status: .noCoverage, activated: false)
        let report = MutationReport(
            scope: .init(sources: [record.source], tests: [], allTests: true),
            mutants: [record],
            timings: .init(baselineSeconds: 2.5, schemaBuildSeconds: 3.25)
        )
        try MutationReportWriter.write(report, to: directory, sourceContents: [record.source: "let enabled = true"])
        let strykerData = try Data(contentsOf: directory.appendingPathComponent("stryker.json"))
        let root = try #require(JSONSerialization.jsonObject(with: strykerData) as? [String: Any])
        let files = try #require(root["files"] as? [String: [String: Any]])
        let file = try #require(files[record.source])
        #expect(file["language"] as? String == "swift")
        #expect(file["source"] as? String == "let enabled = true")
        let mutants = try #require(file["mutants"] as? [[String: Any]])
        #expect(mutants.first?["status"] as? String == "NoCoverage")
        #expect(mutants.first?["replacement"] as? String == "false")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path))
        let canonicalData = try Data(contentsOf: directory.appendingPathComponent("report.json"))
        let canonical = try #require(JSONSerialization.jsonObject(with: canonicalData) as? [String: Any])
        let timings = try #require(canonical["timings"] as? [String: Double])
        #expect(timings["baselineSeconds"] == 2.5)
        let markdown = try String(contentsOf: directory.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(markdown.contains("| Schema build | 3.25 |"))
    }

    @Test("respects requested report formats")
    func selectedFormats() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = MutationReport(scope: .init(sources: [], tests: [], allTests: true), mutants: [])
        try MutationReportWriter.write(report, to: directory, formats: ["json"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("stryker.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("report.md").path))
    }
}
