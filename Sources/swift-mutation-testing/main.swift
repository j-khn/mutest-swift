import Foundation
import SwiftMutationTesting
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { if case .usage(let message) = self { return message }; return "Unknown CLI error." }
}

struct Arguments {
    var command: String
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    mutating func add(_ key: String, _ value: String) { values[key, default: []].append(value) }
    func first(_ key: String) -> String? { values[key]?.last }
    func all(_ key: String) -> [String] { values[key] ?? [] }
}

@main
enum SwiftMutationTestingCLI {
    static func main() {
        ProcessRunner.installCancellationHandlers()
        do {
            let arguments = try parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.command == "help" || arguments.flags.contains("--help") || arguments.flags.contains("-h") { print(help); return }
            if arguments.command == "version" { print("mutest-swift 0.3.0"); return }
            if arguments.command == "validate" {
                let configuration = try makeConfiguration(arguments)
                _ = try xcodebuildArguments(arguments, projectKind: configuration.project.kind)
                try validate(configuration)
                print("Configuration valid. Project: \(configuration.project.kind.rawValue) at \(configuration.project.path)")
                return
            }
            guard arguments.command == "run" else { throw CLIError.usage("Expected command 'run', 'validate', 'version', or 'help'.\n\n\(help)") }
            let configuration = try makeConfiguration(arguments)
            let buildSettings = try xcodebuildArguments(arguments, projectKind: configuration.project.kind)
            let output = arguments.first("--output").map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL }
            let runStartedAt = Date()
            let report = try MutationEngine(xcodebuildArguments: buildSettings).run(configuration: configuration, outputDirectory: output)
            let runDuration = Date().timeIntervalSince(runStartedAt)
            let score = report.summary.score.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
            print("Mutation score: \(score) · killed \(report.summary.killed) · survived \(report.summary.survived) · no coverage \(report.summary.noCoverage) · timeout \(report.summary.timedOut) · unbuildable \(report.summary.unbuildable)")
            print("[mutest-swift] Complete: \(report.summary.generated) mutants across \(report.scope.sources.count) source files in \(formatDuration(runDuration)).")
            let projectURL = URL(fileURLWithPath: configuration.project.path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            let projectRoot = configuration.project.kind == .swiftPackage ? projectURL : projectURL.deletingLastPathComponent()
            let configuredOutput = configuration.output.directory.map { URL(fileURLWithPath: $0, relativeTo: projectRoot).standardizedFileURL }
            let reportDirectory = output ?? configuredOutput ?? projectRoot.appendingPathComponent(".swift-mutation-testing")
            print("Reports: \(reportDirectory.path)")
            if let gate = report.qualityGate, !gate.passed {
                for failure in gate.failures { fputs("Quality gate: \(failure)\n", stderr) }
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func parse(_ arguments: [String]) throws -> Arguments {
        guard let command = arguments.first else { return Arguments(command: "help") }
        if command == "--help" || command == "-h" { return Arguments(command: "help") }
        var parsed = Arguments(command: command)
        let valueOptions: Set<String> = [
            "--config", "--project", "--project-kind", "--mutation-source", "--source", "--test-file", "--target-file",
            "--test-suite", "--suite", "--test-name", "--target-tests", "--test", "--scheme", "--test-target", "--target", "--test-package-root",
            "--destination", "--destination-simulator", "--xcodebuild-arg", "--operators", "--operator-tier", "--build-timeout",
            "--baseline-timeout", "--mutant-timeout", "--parallelism", "--workers", "--output", "--cache-path", "--minimum-score",
            "--maximum-score-drop", "--maximum-integrity-warnings", "--baseline-report"
        ]
        let canonicalOptions = [
            "--mutation-source": "--source",
            "--target-file": "--test-file",
            "--test-suite": "--suite",
            "--test-name": "--test",
            "--target-tests": "--test",
            "--target": "--test-target",
            "--destination-simulator": "--destination",
            "--workers": "--parallelism",
        ]
        let flagOptions: Set<String> = ["--no-resume", "--no-cache", "--no-suppressions", "--require-suppression-reason", "--fail-on-new-survivors", "--help", "-h"]
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            if flagOptions.contains(option) { parsed.flags.insert(option); index += 1; continue }
            guard valueOptions.contains(option), index + 1 < arguments.count else { throw CLIError.usage("Unknown or incomplete option: \(option)") }
            parsed.add(canonicalOptions[option] ?? option, arguments[index + 1]); index += 2
        }
        return parsed
    }

    static func makeConfiguration(_ arguments: Arguments) throws -> RunConfiguration {
        var config: RunConfiguration
        if let configPath = arguments.first("--config") {
            let url = URL(fileURLWithPath: configPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            let data = try Data(contentsOf: url)
            config = try JSONDecoder().decode(RunConfiguration.self, from: data)
            if !config.project.path.hasPrefix("/") {
                config.project.path = url.deletingLastPathComponent().appendingPathComponent(config.project.path).standardizedFileURL.path
            }
            if let baseline = config.qualityGate.baselineReport, !baseline.hasPrefix("/") {
                config.qualityGate.baselineReport = url.deletingLastPathComponent().appendingPathComponent(baseline).standardizedFileURL.path
            }
            if let cachePath = config.cache.path, !cachePath.hasPrefix("/") {
                config.cache.path = url.deletingLastPathComponent().appendingPathComponent(cachePath).standardizedFileURL.path
            }
            if let outputDirectory = config.output.directory, !outputDirectory.hasPrefix("/") {
                config.output.directory = url.deletingLastPathComponent().appendingPathComponent(outputDirectory).standardizedFileURL.path
            }
        } else {
            config = RunConfiguration()
        }
        if let path = arguments.first("--project") { config.project.path = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path }
        if let value = arguments.first("--project-kind") {
            switch value {
            case "swift-package": config.project.kind = .swiftPackage
            case "xcode-project": config.project.kind = .xcodeProject
            case "xcode-workspace": config.project.kind = .xcodeWorkspace
            default: throw CLIError.usage("--project-kind must be swift-package, xcode-project, or xcode-workspace.")
            }
        }
        if !arguments.all("--source").isEmpty { config.source = arguments.all("--source") }
        if !arguments.all("--test-file").isEmpty { config.tests.files = arguments.all("--test-file") }
        if !arguments.all("--suite").isEmpty { config.tests.suites = arguments.all("--suite") }
        if !arguments.all("--test").isEmpty { config.tests.tests = arguments.all("--test") }
        if let scheme = arguments.first("--scheme") { config.project.scheme = scheme }
        if !arguments.all("--test-target").isEmpty { config.project.testTargets = arguments.all("--test-target") }
        if !arguments.all("--test-package-root").isEmpty { config.project.testPackageRoots = arguments.all("--test-package-root") }
        if let destination = arguments.first("--destination") { config.project.destination = destination }
        if let operators = arguments.first("--operators") {
            config.operators = try operators.split(separator: ",").map { name in
                guard let value = MutationOperator(rawValue: String(name)) else { throw CLIError.usage("Unknown operator '\(name)'.") }
                return value
            }
        }
        if let tier = arguments.first("--operator-tier") {
            guard ["conservative", "default", "experimental", "all"].contains(tier) else { throw CLIError.usage("Unknown operator tier '\(tier)'.") }
            config.operatorTier = tier
            if tier == "conservative" || tier == "default" {
                throw CLIError.usage("No operators have enough real-package campaign data for the '\(tier)' tier yet. Use --operator-tier experimental while all operators remain experimental.")
            }
        }
        if let seconds = arguments.first("--build-timeout") { config.timeouts.buildSeconds = try integer(seconds, name: "--build-timeout") }
        if let seconds = arguments.first("--baseline-timeout") { config.timeouts.baselineSeconds = try integer(seconds, name: "--baseline-timeout") }
        if let seconds = arguments.first("--mutant-timeout") { config.timeouts.mutantSeconds = try integer(seconds, name: "--mutant-timeout") }
        if let workers = arguments.first("--parallelism") { config.parallelism = try integer(workers, name: "--parallelism") }
        if let cachePath = arguments.first("--cache-path") { config.cache.path = URL(fileURLWithPath: cachePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path }
        if arguments.flags.contains("--no-cache") { config.cache.enabled = false }
        if arguments.flags.contains("--no-suppressions") { config.suppression.enabled = false }
        if arguments.flags.contains("--require-suppression-reason") { config.suppression.requireReason = true }
        if let score = arguments.first("--minimum-score") { config.qualityGate.minimumScore = try fraction(score, name: "--minimum-score") }
        if let drop = arguments.first("--maximum-score-drop") { config.qualityGate.maximumScoreDrop = try fraction(drop, name: "--maximum-score-drop") }
        if let baseline = arguments.first("--baseline-report") { config.qualityGate.baselineReport = URL(fileURLWithPath: baseline, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path }
        if let count = arguments.first("--maximum-integrity-warnings") { config.qualityGate.maximumIntegrityWarnings = try nonnegativeInteger(count, name: "--maximum-integrity-warnings") }
        if arguments.flags.contains("--fail-on-new-survivors") { config.qualityGate.failOnNewSurvivors = true }
        if arguments.flags.contains("--no-resume") { config.resume = false }
        return config
    }

    static func validate(_ configuration: RunConfiguration) throws {
        let root = URL(fileURLWithPath: configuration.project.path, isDirectory: true).standardizedFileURL
        switch configuration.project.kind {
        case .swiftPackage:
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else { throw CLIError.usage("No Package.swift at \(root.path).") }
        case .xcodeProject, .xcodeWorkspace:
            guard let scheme = configuration.project.scheme, !scheme.isEmpty else { throw CLIError.usage("Xcode projects/workspaces require --scheme.") }
            let path = URL(fileURLWithPath: configuration.project.path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            guard FileManager.default.fileExists(atPath: path.path) else { throw CLIError.usage("Xcode project/workspace does not exist at \(path.path).") }
        }
        if configuration.project.kind == .swiftPackage {
            _ = try SwiftTestSelectorResolver().resolve(projectRoot: root, selection: configuration.tests)
        }
    }

    static func xcodebuildArguments(_ arguments: Arguments, projectKind: ProjectKind) throws -> [String] {
        let values = arguments.all("--xcodebuild-arg")
        guard values.isEmpty || projectKind != .swiftPackage else {
            throw CLIError.usage("--xcodebuild-arg can only be used with Xcode projects or workspaces.")
        }
        guard values.allSatisfy({ value in
            guard let separator = value.firstIndex(of: "=") else { return false }
            return separator != value.startIndex
        }) else {
            throw CLIError.usage("Each --xcodebuild-arg must be a build setting in NAME=VALUE form.")
        }
        return values
    }

    static func integer(_ text: String, name: String) throws -> Int {
        guard let value = Int(text), value > 0 else { throw CLIError.usage("\(name) must be a positive integer.") }
        return value
    }

    static func nonnegativeInteger(_ text: String, name: String) throws -> Int {
        guard let value = Int(text), value >= 0 else { throw CLIError.usage("\(name) must be a non-negative integer.") }
        return value
    }

    static func fraction(_ text: String, name: String) throws -> Double {
        guard let value = Double(text), value >= 0, value <= 1 else { throw CLIError.usage("\(name) must be between 0 and 1.") }
        return value
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static let help = """
    mutest-swift 0.3.0

    Usage:
      swift-mutation-testing run [options]
      swift-mutation-testing validate [options]
      swift-mutation-testing version

    Project:
      --project PATH                 Project root (default: .)
      --project-kind KIND            swift-package | xcode-project | xcode-workspace
      --scheme NAME                  Xcode scheme
      --test-package-root PATH       Package whose test files belong to the scheme; repeatable
      --destination-simulator VALUE  iOS Simulator for Xcode tests, e.g. platform=iOS Simulator,name=iPhone 17,OS=latest
      --xcodebuild-arg NAME=VALUE    Xcode build setting; repeatable

    Code to mutate:
      --mutation-source PATH         Production Swift file/folder; repeat once per path

    Tests to run:
      --test-target NAME             Xcode test target to run in full; repeat for more targets
      --test-file PATH               File containing tests; repeat once per file
      --test-suite NAME              Suite grouping name or @Suite display name; repeat once per suite
      --test-name NAME               Test function or custom test name; repeat once per test
      Target and test selectors are combined: whole targets plus matching files/suites/tests.
      File, suite, and test selectors can resolve to other test targets in the selected scheme.
      Example: --test-target A --test-target B --test-file CTests.swift runs all A/B tests plus tests in that file.
      Add --test-suite or --test-name to include matches from more targets. Duplicate names need TargetName::selector.

    General options:
      --operators IDS                Comma-separated canonical operator IDs
      --operator-tier TIER           conservative | default | experimental | all
      --config PATH                  JSON run configuration

    Execution and gates:
      --build-timeout SECONDS        Build timeout (default 600)
      --baseline-timeout SECONDS     Baseline test timeout (default 300)
      --mutant-timeout SECONDS       Per-mutant timeout (default 120)
      --workers COUNT                Simultaneous mutant workers (default 2)
      --cache-path DIR               Cache journal directory (default: report directory)
      --no-cache                     Disable journal reads and writes
      --no-resume                    Do not reuse prior journal verdicts
      --no-suppressions              Ignore source suppression comments
      --require-suppression-reason   Ignore suppression comments without a reason
      --minimum-score FRACTION       Minimum score in the range 0...1
      --maximum-score-drop FRACTION  Maximum allowed baseline drop in the range 0...1
      --baseline-report PATH         Previous report used by score-drop and new-survivor gates
      --maximum-integrity-warnings N Integrity warning limit (default 0)
      --fail-on-new-survivors        Fail when new survivors are supplied to the gate API
      --output PATH                  Report directory (default: .swift-mutation-testing)

    With no test selectors or targets, all tests in the configured Swift package or Xcode scheme's test plan run.
    Each --test-target adds every test in that target. Each file, suite, or test selector adds its matches,
    even when they belong to a different target. All selected targets must be included in the chosen scheme/test plan.
    --test-file selects every test in that file; use --test-name to choose individual tests.
    Source selection never narrows tests automatically, allowing full-suite ripple checks for changed source files.

    Older aliases remain accepted: --source, --target, --target-file, --target-tests, --test, --suite,
    --destination, and --parallelism.
    """
}
