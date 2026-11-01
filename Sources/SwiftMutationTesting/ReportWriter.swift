import Foundation
import MutationTestingSpec

public struct MutationRunSummaryDetails: Codable, Sendable {
    public var testTarget: String?
    public var baselineTestCount: Int?
    public var mutantTestRunCount: Int
    public var totalDurationSeconds: Double
    public var requestedWorkerCount: Int
    public var activeWorkerCount: Int
    public var baselineRunCount: Int
    public var baselineTestExecutionCount: Int?
    public var simulatorSetupSeconds: Double

    public init(testTarget: String? = nil, baselineTestCount: Int? = nil, mutantTestRunCount: Int = 0, totalDurationSeconds: Double = 0, requestedWorkerCount: Int = 1, activeWorkerCount: Int = 1, baselineRunCount: Int = 1, baselineTestExecutionCount: Int? = nil, simulatorSetupSeconds: Double = 0) {
        self.testTarget = testTarget
        self.baselineTestCount = baselineTestCount
        self.mutantTestRunCount = mutantTestRunCount
        self.totalDurationSeconds = totalDurationSeconds
        self.requestedWorkerCount = requestedWorkerCount; self.activeWorkerCount = activeWorkerCount
        self.baselineRunCount = baselineRunCount; self.baselineTestExecutionCount = baselineTestExecutionCount
        self.simulatorSetupSeconds = simulatorSetupSeconds
    }
}

public enum MutationReportWriter {
    public static func write(
        _ report: MutationReport,
        to directory: URL,
        sourceContents: [String: String] = [:],
        formats: Set<String> = ["console", "json", "markdown"],
        runDetails: MutationRunSummaryDetails? = nil
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if formats.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var document = try JSONSerialization.jsonObject(with: encoder.encode(report)) as! [String: Any]
            if let runDetails { document["execution"] = try JSONSerialization.jsonObject(with: encoder.encode(runDetails)) }
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            try encoder.encode(StrykerCompatibleReport(report: report, sourceContents: sourceContents)).write(to: directory.appendingPathComponent("stryker.json"), options: .atomic)
        }
        if formats.contains("markdown") {
            try markdown(report, runDetails: runDetails).write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
    }

    public static func markdown(_ report: MutationReport, runDetails: MutationRunSummaryDetails? = nil) -> String {
        let score = report.summary.score.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        var output = "# Mutation testing report\n\n"
        output += "- **Mutation score:** \(score)\n"
        output += "- **Detected:** \(report.summary.detected) · **Undetected:** \(report.summary.undetected)\n"
        output += "- **Killed:** \(report.summary.killed) · **Survived:** \(report.summary.survived) · **No coverage:** \(report.summary.noCoverage) · **Timeout:** \(report.summary.timedOut)\n"
        output += "- **Unbuildable:** \(report.summary.unbuildable) · **Suppressed:** \(report.summary.suppressed)\n"
        output += "- **Run:** `\(report.runId)` · **Spec:** \(report.specVersion) · **Engine:** \(report.engine.version)\n\n"
        if let runDetails {
            output += "## Run summary\n\n"
            output += "- **Source files selected:** \(report.scope.sources.count)\n"
            output += "- **Mutants generated:** \(report.summary.generated)\n"
            let scopeDescription: String
            if report.scope.allTests {
                if let target = runDetails.testTarget, !target.isEmpty {
                    scopeDescription = "All tests in target `\(target)`"
                } else {
                    scopeDescription = "All tests in the configured test target"
                }
            } else {
                scopeDescription = "\(report.scope.tests.count) selected test(s)"
            }
            if let count = runDetails.baselineTestCount {
                output += "- **Baseline tests per worker:** \(count)\n"
            } else {
                output += "- **Baseline tests run:** count unavailable\n"
            }
            output += "- **Baseline runs:** \(runDetails.baselineRunCount)"
            if let count = runDetails.baselineTestExecutionCount { output += " (\(count) total baseline test executions)" }
            output += "\n"
            output += "- **Workers:** \(runDetails.activeWorkerCount) active / \(runDetails.requestedWorkerCount) requested\n"
            output += String(format: "- **Simulator setup:** %.2fs\n", runDetails.simulatorSetupSeconds)
            output += "- **Test selection:** \(scopeDescription)\n"
            if !report.scope.allTests, !report.scope.tests.isEmpty {
                for test in report.scope.tests.sorted() { output += "  - `\(test)`\n" }
            }
            output += "- **Mutant test runs:** \(runDetails.mutantTestRunCount) (a run may stop after an active mutant is killed)\n"
            output += "- **Total time:** \(formatDuration(runDetails.totalDurationSeconds))\n\n"
        }
        if let timings = report.timings {
            output += "## Phase timings\n\n"
            output += "| Phase | Seconds |\n|---|---:|\n"
            output += String(format: "| Sandbox copy | %.2f |\n", timings.sandboxCopySeconds)
            output += String(format: "| Test discovery | %.2f |\n", timings.testDiscoverySeconds)
            output += String(format: "| Source discovery | %.2f |\n", timings.sourceDiscoverySeconds)
            output += String(format: "| Input hashing | %.2f |\n", timings.inputHashSeconds)
            output += String(format: "| Baseline | %.2f |\n", timings.baselineSeconds)
            output += String(format: "| Schema build | %.2f |\n", timings.schemaBuildSeconds)
            output += String(format: "| Mutant runs | %.2f |\n", timings.mutantRunSeconds)
            output += String(format: "| Isolated builds | %.2f |\n", timings.isolatedBuildSeconds)
            output += String(format: "| Cleanup | %.2f |\n\n", timings.cleanupSeconds)
        }
        if !report.integrityWarnings.isEmpty {
            output += "## Integrity warnings\n\n"
            for warning in report.integrityWarnings { output += "- **\(warning.code):** \(warning.message)\n" }
            output += "\n"
        }
        output += "## Mutants\n\n| Status | Operator | Source | Line | Original → replacement |\n|---|---|---|---:|---|\n"
        for mutant in report.mutants {
            let original = mutant.original.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            let replacement = mutant.replacement.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            output += "| \(mutant.status.rawValue) | \(mutant.operatorID.rawValue) | `\(mutant.source)` | \(mutant.line) | `\(original)` → `\(replacement)` |\n"
        }
        if let gate = report.qualityGate {
            output += "\n## Quality gate\n\n"
            output += gate.passed ? "Passed\n" : "Failed\n"
            for failure in gate.failures { output += "- \(failure)\n" }
        }
        return output
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(remainingSeconds)s" }
        if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
        return "\(remainingSeconds)s"
    }
}

private struct StrykerCompatibleReport: Encodable {
    struct Location: Encodable {
        struct Point: Encodable { var line: Int; var column: Int }
        var start: Point
        var end: Point
    }
    struct Mutant: Encodable {
        var id: String
        var mutatorName: String
        var replacement: String
        var location: Location
        var status: String
        var killedBy: [String]
        var duration: Double
        var description: String
    }
    struct FileEntry: Encodable { var language: String; var source: String; var mutants: [Mutant] }
    var schemaVersion = "1.0.0"
    var thresholds: [String: Int]
    var files: [String: FileEntry]

    init(report: MutationReport, sourceContents: [String: String]) {
        thresholds = ["high": 80, "low": 60]
        var grouped: [String: [Mutant]] = [:]
        for record in report.mutants {
            let status: String
            switch record.status {
            case .killed: status = "Killed"
            case .survived: status = "Survived"
            case .noCoverage: status = "NoCoverage"
            case .timeout: status = "Timeout"
            case .unbuildable: status = "CompileError"
            case .suppressed: status = "Ignored"
            }
            let mutant = Mutant(
                id: record.id,
                mutatorName: record.operatorID.rawValue,
                replacement: record.replacement,
                location: .init(start: .init(line: record.line, column: record.column), end: .init(line: record.line + record.original.filter(\.isNewline).count, column: Self.endColumn(record))),
                status: status,
                killedBy: [],
                duration: (record.durationSeconds ?? 0) * 1_000,
                description: "\(record.operatorID.rawValue): \(record.original) -> \(record.replacement)"
            )
            grouped[record.source, default: []].append(mutant)
        }
        files = Dictionary(uniqueKeysWithValues: grouped.map { path, mutants in
            (path, FileEntry(language: "swift", source: sourceContents[path] ?? "", mutants: mutants))
        })
    }

    private static func endColumn(_ record: MutantRecord) -> Int {
        guard let newline = record.original.lastIndex(of: "\n") else { return record.column + max(1, record.original.utf8.count) }
        return max(1, record.original[record.original.index(after: newline)...].utf8.count + 1)
    }
}
