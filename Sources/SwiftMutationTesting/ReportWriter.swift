import Foundation

public struct MutationTestCaseDetails: Codable, Hashable, Sendable {
    public var identifier: String
    public var name: String
    public var testFile: String?
    public var lineNumber: Int?
    public var result: String?
}

public struct MutantTestRunDetails: Codable, Sendable {
    public var mutantId: String
    public var source: String
    public var reportedCaseCount: Int?
    public var testCases: [MutationTestCaseDetails]?
}

public struct MutationRunSummaryDetails: Codable, Sendable {
    public var testTarget: String?
    public var baselineTestCount: Int?
    public var mutantTestRunCount: Int
    public var totalDurationSeconds: Double
    public var requestedWorkerCount: Int
    public var activeWorkerCount: Int
    public var baselineRunCount: Int
    public var baselineTestExecutionCount: Int?
    public var mutantTestCaseExecutionCount: Int?
    public var mutantTestRunCountWithoutReportedCaseCount: Int
    public var mutantTestRuns: [MutantTestRunDetails]
    public var simulatorSetupSeconds: Double

    public init(testTarget: String? = nil, baselineTestCount: Int? = nil, mutantTestRunCount: Int = 0, totalDurationSeconds: Double = 0, requestedWorkerCount: Int = 1, activeWorkerCount: Int = 1, baselineRunCount: Int = 1, baselineTestExecutionCount: Int? = nil, mutantTestCaseExecutionCount: Int? = nil, mutantTestRunCountWithoutReportedCaseCount: Int = 0, mutantTestRuns: [MutantTestRunDetails] = [], simulatorSetupSeconds: Double = 0) {
        self.testTarget = testTarget
        self.baselineTestCount = baselineTestCount
        self.mutantTestRunCount = mutantTestRunCount
        self.totalDurationSeconds = totalDurationSeconds
        self.requestedWorkerCount = requestedWorkerCount; self.activeWorkerCount = activeWorkerCount
        self.baselineRunCount = baselineRunCount; self.baselineTestExecutionCount = baselineTestExecutionCount
        self.mutantTestCaseExecutionCount = mutantTestCaseExecutionCount
        self.mutantTestRunCountWithoutReportedCaseCount = mutantTestRunCountWithoutReportedCaseCount
        self.mutantTestRuns = mutantTestRuns
        self.simulatorSetupSeconds = simulatorSetupSeconds
    }
}

public enum MutationReportWriter {
    public static func write(
        _ report: MutationReport,
        to directory: URL,
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
        output += "- **Run:** `\(report.runId)` · **Engine:** \(report.engine.version)\n\n"
        if let runDetails {
            output += "## Run summary\n\n"
            output += "- **Source files selected:** \(report.scope.sources.count)\n"
            output += "- **Mutants generated:** \(report.summary.generated)\n"
            let scopeDescription: String
            let wholeTargets = report.scope.tests.filter { report.scope.testTargets.contains($0) }.sorted()
            let explicitTests = report.scope.tests.filter { !report.scope.testTargets.contains($0) }.sorted()
            if report.scope.allTests {
                scopeDescription = "All tests configured for the package or Xcode scheme"
            } else if !wholeTargets.isEmpty && !explicitTests.isEmpty {
                scopeDescription = "All tests in \(wholeTargets.map { "`\($0)`" }.joined(separator: ", ")) plus \(explicitTests.count) selected test(s)"
            } else if !wholeTargets.isEmpty {
                scopeDescription = "All tests in \(wholeTargets.map { "`\($0)`" }.joined(separator: ", "))"
            } else {
                scopeDescription = "\(explicitTests.count) selected test(s) across \(report.scope.testTargets.count) target(s)"
            }
            if let count = runDetails.baselineTestCount {
                output += "- **Baseline tests per worker:** \(count)\n"
            } else {
                output += "- **Baseline tests run:** count unavailable\n"
            }
            output += "- **Baseline runs:** \(runDetails.baselineRunCount)"
            if let count = runDetails.baselineTestExecutionCount { output += " (\(count) reported tests across all baseline runs)" }
            output += "\n"
            if let count = runDetails.mutantTestCaseExecutionCount {
                output += "- **Mutant test cases reported:** \(count)\n"
                if let baselineCount = runDetails.baselineTestExecutionCount {
                    output += "- **Total reported test executions:** \(baselineCount + count)\n"
                }
            }
            if runDetails.mutantTestRunCountWithoutReportedCaseCount > 0 {
                output += "- **Mutant runs without a reported test count:** \(runDetails.mutantTestRunCountWithoutReportedCaseCount)\n"
            }
            appendTestsByMutatedFile(report, runDetails: runDetails, to: &output)
            output += "- **Workers:** \(runDetails.activeWorkerCount) active / \(runDetails.requestedWorkerCount) requested\n"
            output += String(format: "- **Simulator setup:** %.2fs\n", runDetails.simulatorSetupSeconds)
            output += "- **Test selection:** \(scopeDescription)\n"
            if !report.scope.allTests, !explicitTests.isEmpty {
                for test in explicitTests { output += "  - `\(test)`\n" }
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

    private static func appendTestsByMutatedFile(_ report: MutationReport, runDetails: MutationRunSummaryDetails, to output: inout String) {
        guard !runDetails.mutantTestRuns.isEmpty else { return }
        let runsBySource = Dictionary(grouping: runDetails.mutantTestRuns, by: \.source)
        output += "\n### Unit tests by mutated file\n\n"
        output += "| Mutated file | Mutants run | Test runs | Unit test executions reported | Unique unit tests observed | Test files observed |\n"
        output += "|---|---:|---:|---:|---:|---:|\n"

        for source in report.scope.sources.sorted() {
            let runs = runsBySource[source, default: []]
            let mutantCount = Set(runs.map(\.mutantId)).count
            let reportedCounts = runs.compactMap(\.reportedCaseCount)
            let unknownCount = runs.count - reportedCounts.count
            let testCount = reportedCounts.reduce(0, +)
            let testCases = uniqueTestCases(in: runs)
            let testFiles = Set(testCases.compactMap(\.testFile)).count
            let testCountLabel = unknownCount == 0 ? String(testCount) : "\(testCount) (+\(unknownCount) unreported)"
            output += "| `\(markdownCell(source))` | \(mutantCount) | \(runs.count) | \(testCountLabel) | \(testCases.count) | \(testFiles) |\n"
        }
        output += "\n"

        let sourcesWithTestNames = runsBySource.keys.filter { !(runsBySource[$0] ?? []).allSatisfy { $0.testCases?.isEmpty ?? true } }.sorted()
        guard !sourcesWithTestNames.isEmpty else { return }
        output += "<details>\n<summary>Unit test names by mutated file</summary>\n\n"
        for source in sourcesWithTestNames {
            let runs = runsBySource[source, default: []]
            output += "#### `\(markdownCell(source))`\n\n"
            for testCase in uniqueTestCases(in: runs) {
                let fileLocation: String
                if let file = testCase.testFile {
                    fileLocation = testCase.lineNumber.map { " — `\(markdownCell(file)):\($0)`" } ?? " — `\(markdownCell(file))`"
                } else { fileLocation = "" }
                output += "- `\(markdownCell(testCase.name))`\(fileLocation)\n"
            }
            if runs.contains(where: { $0.testCases == nil }) {
                output += "- Some mutant result bundles did not include a test-name list.\n"
            }
            output += "\n"
        }
        output += "</details>\n\n"
    }

    private static func uniqueTestCases(in runs: [MutantTestRunDetails]) -> [MutationTestCaseDetails] {
        var cases: [String: MutationTestCaseDetails] = [:]
        for testCase in runs.flatMap({ $0.testCases ?? [] }) { cases[testCase.identifier] = testCase }
        return cases.values.sorted {
            if $0.testFile != $1.testFile { return ($0.testFile ?? "") < ($1.testFile ?? "") }
            if $0.lineNumber != $1.lineNumber { return ($0.lineNumber ?? 0) < ($1.lineNumber ?? 0) }
            return $0.name < $1.name
        }
    }

    private static func markdownCell(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "\\`")
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
