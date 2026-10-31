import Foundation
import MutationTestingSpec

public enum MutationReportWriter {
    public static func write(
        _ report: MutationReport,
        to directory: URL,
        sourceContents: [String: String] = [:],
        formats: Set<String> = ["console", "json", "markdown"]
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if formats.contains("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            try encoder.encode(StrykerCompatibleReport(report: report, sourceContents: sourceContents)).write(to: directory.appendingPathComponent("stryker.json"), options: .atomic)
        }
        if formats.contains("markdown") {
            try markdown(report).write(to: directory.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
    }

    public static func markdown(_ report: MutationReport) -> String {
        let score = report.summary.score.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        var output = "# Mutation testing report\n\n"
        output += "- **Mutation score:** \(score)\n"
        output += "- **Detected:** \(report.summary.detected) · **Undetected:** \(report.summary.undetected)\n"
        output += "- **Killed:** \(report.summary.killed) · **Survived:** \(report.summary.survived) · **No coverage:** \(report.summary.noCoverage) · **Timeout:** \(report.summary.timedOut)\n"
        output += "- **Unbuildable:** \(report.summary.unbuildable) · **Suppressed:** \(report.summary.suppressed)\n"
        output += "- **Run:** `\(report.runId)` · **Spec:** \(report.specVersion) · **Engine:** \(report.engine.version)\n\n"
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
