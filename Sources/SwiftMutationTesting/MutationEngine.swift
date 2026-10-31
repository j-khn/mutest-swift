import Foundation
import MutationTestingSpec

public enum MutationEngineError: Error, CustomStringConvertible {
    case invalidProject(String)
    case baselineFailed(log: URL, timedOut: Bool)
    case baselineRanNoTests(log: URL)
    case noSourceFiles(String)
    case invalidSelection(String)
    public var description: String {
        switch self {
        case .invalidProject(let message), .noSourceFiles(let message), .invalidSelection(let message): return message
        case .baselineFailed(let log, let timedOut): return "Baseline tests \(timedOut ? "timed out" : "failed"); no mutation score was produced. Log: \(log.path)"
        case .baselineRanNoTests(let log): return "Baseline command succeeded but ran zero tests; no mutation score was produced. Check test selectors and log: \(log.path)"
        }
    }
}

private struct JournalEntry: Codable {
    var cacheKey: String
    var record: MutantRecord
    var warnings: [IntegrityWarning]

    init(cacheKey: String, record: MutantRecord, warnings: [IntegrityWarning] = []) {
        self.cacheKey = cacheKey; self.record = record; self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey { case cacheKey, record, warnings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cacheKey = try values.decode(String.self, forKey: .cacheKey)
        record = try values.decode(MutantRecord.self, forKey: .record)
        warnings = try values.decodeIfPresent([IntegrityWarning].self, forKey: .warnings) ?? []
    }
}

private final class MutationRunResults: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MutantRecord] = [:]
    private var warnings: [IntegrityWarning] = []
    private var retries: [MutationCandidate] = []

    func store(_ record: MutantRecord, warning: IntegrityWarning? = nil, retry: MutationCandidate? = nil) {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
        if let warning { warnings.append(warning) }
        if let retry { retries.append(retry) }
    }

    func snapshot() -> (records: [String: MutantRecord], warnings: [IntegrityWarning], retries: [MutationCandidate]) {
        lock.lock(); defer { lock.unlock() }
        return (records, warnings, retries)
    }
}

private final class LockedJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    init(url: URL) { self.url = url }
    func append(_ entry: JournalEntry) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(entry) + Data([0x0a])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

public struct MutationEngine: Sendable {
    public init() {}

    public func run(configuration: RunConfiguration, outputDirectory: URL? = nil) throws -> MutationReport {
        let projectURL = URL(fileURLWithPath: configuration.project.path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let root = configuration.project.kind == .swiftPackage ? projectURL : projectURL.deletingLastPathComponent()
        var adapterProject = configuration.project
        if configuration.project.kind != .swiftPackage { adapterProject.path = projectURL.lastPathComponent }
        try validate(configuration: configuration, root: root, projectURL: projectURL)
        let configuredOutput = configuration.output.directory.map {
            URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL
        }
        let output = outputDirectory ?? configuredOutput ?? root.appendingPathComponent(".swift-mutation-testing", isDirectory: true)
        let cacheDirectory = configuration.cache.path.map { URL(fileURLWithPath: $0, relativeTo: root).standardizedFileURL }
        let logs = output.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let sandbox = try makeSandbox(
            from: root,
            into: output.appendingPathComponent("sandboxes", isDirectory: true),
            excluding: [output] + (cacheDirectory.map { [$0] } ?? [])
        )
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: configuration.tests,
            testTarget: configuration.project.testTarget,
            forXcode: configuration.project.kind != .swiftPackage
        )
        let adapter = NativeTestAdapter(project: adapterProject, selection: configuration.tests)
        let runner = ProcessRunner()
        let baselineLog = logs.appendingPathComponent("baseline.log")
        let baseline = try runner.run(adapter.command(root: sandbox, phase: .baseline, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.baselineSeconds), output: baselineLog))
        guard !baseline.timedOut && baseline.exitCode == 0 else { throw MutationEngineError.baselineFailed(log: baselineLog, timedOut: baseline.timedOut) }
        guard let baselineTestCount = executedTestCount(in: baseline.output), baselineTestCount > 0 else {
            throw MutationEngineError.baselineRanNoTests(log: baselineLog)
        }

        let sourceFiles = try discoverSources(root: root, requested: configuration.source, kind: configuration.project.kind)
        guard !sourceFiles.isEmpty else { throw MutationEngineError.noSourceFiles("No Swift source files found in the selected source scope.") }
        var candidates: [MutationCandidate] = []
        let generator = SwiftMutationGenerator()
        for file in sourceFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let relative = relativePath(file, root: root)
            candidates += generator.generate(source: contents, relativePath: relative, operators: Set(configuration.operators), suppression: configuration.suppression)
        }
        candidates.sort { ($0.source, $0.span.start) < ($1.source, $1.span.start) }

        var digestConfiguration = configuration
        digestConfiguration.project.path = configuration.project.kind == .swiftPackage ? "." : adapterProject.path
        digestConfiguration.cache = .init(enabled: true)
        digestConfiguration.resume = true
        digestConfiguration.qualityGate = .init()
        digestConfiguration.output = .init()
        let journalDirectory = cacheDirectory ?? output
        let inputDigest = try digestInputs(root: root, files: sourceFiles, configuration: digestConfiguration, excluding: [output, journalDirectory])
        let journal = journalDirectory.appendingPathComponent("journal.jsonl")
        let cached = configuration.cache.enabled ? loadJournal(at: journal) : []
        var records: [String: MutantRecord] = [:]
        var warnings: [IntegrityWarning] = []
        for candidate in candidates where candidate.suppressionReason != nil {
            var record = candidate.record
            record.status = .suppressed
            record.suppressionReason = candidate.suppressionReason
            records[candidate.id] = record
        }
        let runnable = candidates.filter { $0.suppressionReason == nil }
        var cachedForRun: [String: JournalEntry] = [:]
        for entry in cached where entry.cacheKey.hasPrefix(inputDigest + ":") {
            cachedForRun[String(entry.cacheKey.dropFirst(inputDigest.count + 1))] = entry
        }
        for candidate in runnable {
            if configuration.resume, let entry = cachedForRun[candidate.id] {
                records[candidate.id] = entry.record
                warnings += entry.warnings
            }
        }
        let remaining = runnable.filter { records[$0.id] == nil }

        if !remaining.isEmpty {
            let sourceByRelative = Dictionary(uniqueKeysWithValues: sourceFiles.map { (relativePath($0, root: root), $0) })
            var candidatesBySource: [String: [MutationCandidate]] = [:]
            for item in remaining { candidatesBySource[item.source, default: []].append(item) }

            // Build one schema containing all non-overlapping mutations. The runtime switch
            // activates exactly one ID for each test invocation and writes an activation marker.
            var schemaCandidates: [MutationCandidate] = []
            var isolatedCandidates: [MutationCandidate] = []
            let activationDirectory: URL? = configuration.project.kind == .swiftPackage ? logs : nil
            for (relative, items) in candidatesBySource {
                let original = try String(contentsOf: sourceByRelative[relative]!, encoding: .utf8)
                let schema = generator.makeSchema(source: original, candidates: items)
                schemaCandidates += items.filter { schema.included.contains($0.id) }
                isolatedCandidates += schema.isolated
                let destination = sandbox.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try schema.source.write(to: destination, atomically: true, encoding: .utf8)
            }

            if !schemaCandidates.isEmpty {
                let buildLog = logs.appendingPathComponent("schema-build.log")
                let buildPhase: TestPhase = configuration.project.kind == .swiftPackage ? .buildForTesting : .buildForTesting
                let buildCommand = try adapter.command(root: sandbox, phase: buildPhase, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.buildSeconds), output: buildLog)
                let build = try runner.run(buildCommand)
                if build.timedOut || build.exitCode != 0 {
                    // A schema can fail because a particular rewrite is not type-correct. Retry
                    // every schema member in an isolated source edit before calling it unbuildable.
                    isolatedCandidates += schemaCandidates
                    for original in sourceFiles {
                        let relative = relativePath(original, root: root)
                        let clean = try String(contentsOf: original, encoding: .utf8)
                        try clean.write(to: sandbox.appendingPathComponent(relative), atomically: true, encoding: .utf8)
                    }
                } else {
                    let concurrency = executionConcurrency(root: root, projectKind: configuration.project.kind, requested: configuration.parallelism)
                    let parallelResults = MutationRunResults()
                    let lockedJournal = configuration.cache.enabled ? LockedJournal(url: journal) : nil
                    let currentActivationDirectory = activationDirectory
                    let queue = OperationQueue()
                    queue.name = "swift-mutation-testing.mutants"
                    queue.maxConcurrentOperationCount = concurrency
                    for candidate in schemaCandidates where records[candidate.id] == nil {
                        queue.addOperation {
                            do {
                                let cacheKey = inputDigest + ":" + candidate.id
                                let activation = self.activationFile(for: candidate, in: currentActivationDirectory, useFile: currentActivationDirectory != nil)
                                if let activation { try? FileManager.default.removeItem(at: activation) }
                                var env = ["SWIFT_MUTATION_ID": candidate.id]
                                if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                                let log = logs.appendingPathComponent("mutant-\(candidate.id).log")
                                let command = try adapter.command(root: sandbox, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: TimeInterval(configuration.timeouts.mutantSeconds), output: log)
                                let result = try runner.run(command)
                                let activated = self.activationContains(candidate.id, file: activation, output: result.output)
                                var record = candidate.record
                                record.durationSeconds = result.elapsed
                                record.activated = activated
                                if result.timedOut { record.status = .timeout }
                                else if !activated { record.status = .noCoverage }
                                else { record.status = result.exitCode == 0 ? .survived : .killed }
                                let warning: IntegrityWarning? = executedTestCount(in: result.output) == 0
                                    ? .init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id)
                                    : (!activated && result.exitCode != 0 && !result.timedOut
                                        ? .init(code: "testsFailedWithoutActivation", message: "Test execution failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id)
                                        : nil)
                                let retry = result.timedOut && concurrency > 1 && configuration.timeouts.parallelRetry ? candidate : nil
                                parallelResults.store(record, warning: warning, retry: retry)
                                try lockedJournal?.append(.init(cacheKey: cacheKey, record: record, warnings: warning.map { [$0] } ?? []))
                            } catch {
                                var record = candidate.record
                                record.status = .unbuildable
                                record.message = "Could not execute mutant: \(error)"
                                parallelResults.store(record, warning: .init(code: "mutantExecutionFailed", message: String(describing: error), mutantId: candidate.id))
                            }
                        }
                    }
                    queue.waitUntilAllOperationsAreFinished()
                    if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
                    let completed = parallelResults.snapshot()
                    records.merge(completed.records) { _, new in new }
                    warnings += completed.warnings
                    for candidate in completed.retries {
                        let activation = activationFile(for: candidate, in: activationDirectory, useFile: activationDirectory != nil)
                        if let activation { try? FileManager.default.removeItem(at: activation) }
                        var env = ["SWIFT_MUTATION_ID": candidate.id]
                        if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                        let log = logs.appendingPathComponent("retry-isolated-\(candidate.id).log")
                        let retryTimeout = TimeInterval(configuration.timeouts.mutantSeconds) * configuration.timeouts.retryMultiplier
                        let command = try adapter.command(root: sandbox, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: retryTimeout, output: log)
                        let result = try runner.run(command)
                        let activated = activationContains(candidate.id, file: activation, output: result.output)
                        var record = records[candidate.id] ?? candidate.record
                        record.durationSeconds = (record.durationSeconds ?? 0) + result.elapsed
                        record.activated = activated
                        record.message = "Timed out during parallel execution; retried in isolation with a \(configuration.timeouts.retryMultiplier)x mutant timeout."
                        if result.timedOut { record.status = .timeout }
                        else if !activated { record.status = .noCoverage }
                        else { record.status = result.exitCode == 0 ? .survived : .killed }
                        var retryWarnings: [IntegrityWarning] = []
                        if executedTestCount(in: result.output) == 0 {
                            retryWarnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id))
                        } else if !activated && result.exitCode != 0 && !result.timedOut {
                            retryWarnings.append(.init(code: "testsFailedWithoutActivation", message: "Isolated retry failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id))
                        }
                        warnings += retryWarnings
                        records[candidate.id] = record
                        if configuration.cache.enabled {
                            try appendJournal(.init(cacheKey: inputDigest + ":" + candidate.id, record: record, warnings: retryWarnings), to: journal)
                        }
                    }
                }
            }

            for candidate in isolatedCandidates where records[candidate.id] == nil {
                let cacheKey = inputDigest + ":" + candidate.id
                let original = try String(contentsOf: sourceByRelative[candidate.source]!, encoding: .utf8)
                let relativeFile = sandbox.appendingPathComponent(candidate.source)
                let mutantSource = generator.makeSchema(source: original, candidates: [candidate]).source
                try mutantSource.write(to: relativeFile, atomically: true, encoding: .utf8)
                let log = logs.appendingPathComponent("isolated-\(candidate.id).log")
                let buildLog = logs.appendingPathComponent("isolated-build-\(candidate.id).log")
                let build = try runner.run(adapter.command(root: sandbox, phase: .buildForTesting, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.buildSeconds), output: buildLog))
                var record = candidate.record
                if build.timedOut {
                    record.durationSeconds = build.elapsed
                    record.status = .unbuildable
                    record.message = "Isolated mutant build timed out after \(configuration.timeouts.buildSeconds) seconds; see \(buildLog.path)."
                } else if build.exitCode != 0 {
                    record.durationSeconds = build.elapsed; record.status = .unbuildable; record.message = "Isolated mutant did not compile; see \(buildLog.path)."
                } else {
                    let activation = activationFile(for: candidate, in: activationDirectory, useFile: activationDirectory != nil)
                    if let activation { try? FileManager.default.removeItem(at: activation) }
                    var env = ["SWIFT_MUTATION_ID": candidate.id]
                    if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                    let result = try runner.run(adapter.command(root: sandbox, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: TimeInterval(configuration.timeouts.mutantSeconds), output: log))
                    let wasActivated = activationContains(candidate.id, file: activation, output: result.output)
                    record.durationSeconds = result.elapsed; record.activated = wasActivated
                    if result.timedOut { record.status = .timeout }
                    else if !wasActivated { record.status = .noCoverage }
                    else { record.status = result.exitCode == 0 ? .survived : .killed }
                    var mutantWarnings: [IntegrityWarning] = []
                    if executedTestCount(in: result.output) == 0 {
                        mutantWarnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id))
                    } else if !wasActivated && result.exitCode != 0 && !result.timedOut {
                        mutantWarnings.append(.init(code: "testsFailedWithoutActivation", message: "Test execution failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id))
                    }
                    warnings += mutantWarnings
                    if configuration.cache.enabled {
                        try appendJournal(.init(cacheKey: cacheKey, record: record, warnings: mutantWarnings), to: journal)
                    }
                }
                records[candidate.id] = record
                try original.write(to: relativeFile, atomically: true, encoding: .utf8)
            }
        }

        let orderedRecords = candidates.compactMap { records[$0.id] }
        for record in orderedRecords where record.status == .timeout && !record.activated {
            warnings.append(.init(code: "timeoutWithoutActivation", message: "Mutant timed out before activation could be verified and is not counted as detected.", mutantId: record.id))
        }
        let summary = MutationSummary(records: orderedRecords)
        let baselineReport: MutationReport?
        if let path = configuration.qualityGate.baselineReport {
            let baselineURL = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            let data = try Data(contentsOf: baselineURL)
            baselineReport = try JSONDecoder().decode(MutationReport.self, from: data)
        } else { baselineReport = nil }
        let baselineSurvivors = Set(baselineReport?.mutants.filter { $0.status == .survived }.map(\.id) ?? [])
        let newSurvivors = orderedRecords.filter { $0.status == .survived && !baselineSurvivors.contains($0.id) }.map(\.id)
        let selectedSources = sourceFiles.map { relativePath($0, root: root) }.sorted()
        let baselineScopeMatches = baselineReport.map { baseline in
            baseline.scope.sources.sorted() == selectedSources
                && baseline.scope.tests.sorted() == selection.identifiers.sorted()
                && baseline.scope.allTests == selection.allTests
        } ?? false
        let gate = QualityGateEvaluator.evaluate(
            summary: summary,
            policy: configuration.qualityGate,
            integrityWarningCount: warnings.count,
            baselineScore: baselineReport?.summary.score,
            newSurvivors: newSurvivors,
            baselineConfigured: baselineReport != nil,
            baselineScopeMatches: baselineScopeMatches
        )
        let report = MutationReport(scope: .init(sources: selectedSources, tests: selection.identifiers, allTests: selection.allTests), mutants: orderedRecords, integrityWarnings: warnings, qualityGate: gate)
        let sourceContents = Dictionary(uniqueKeysWithValues: try sourceFiles.map { file in
            (relativePath(file, root: root), try String(contentsOf: file, encoding: .utf8))
        })
        try MutationReportWriter.write(report, to: output, sourceContents: sourceContents, formats: Set(configuration.output.formats))
        return report
    }

    private func validate(configuration: RunConfiguration, root: URL, projectURL: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { throw MutationEngineError.invalidProject("Project path does not exist: \(root.path)") }
        guard configuration.specVersion.split(separator: ".").first == "1" else {
            throw ContractError.invalidConfiguration("This engine supports mutation-testing-spec 1.x; received '\(configuration.specVersion)'.")
        }
        guard configuration.parallelism > 0 else { throw ContractError.invalidConfiguration("parallelism must be at least one") }
        let validOutputFormats: Set<String> = ["console", "json", "markdown"]
        guard !configuration.output.formats.isEmpty, Set(configuration.output.formats).isSubset(of: validOutputFormats) else {
            throw ContractError.invalidConfiguration("output formats must contain one or more of: console, json, markdown")
        }
        if let cachePath = configuration.cache.path, cachePath.isEmpty {
            throw ContractError.invalidConfiguration("cache path cannot be empty")
        }
        guard configuration.timeouts.buildSeconds > 0, configuration.timeouts.baselineSeconds > 0, configuration.timeouts.mutantSeconds > 0,
              configuration.timeouts.retryMultiplier.isFinite, configuration.timeouts.retryMultiplier > 1 else {
            throw ContractError.invalidConfiguration("timeouts must be positive and retryMultiplier must be greater than one")
        }
        if let score = configuration.qualityGate.minimumScore, !(0...1).contains(score) {
            throw ContractError.invalidConfiguration("qualityGate.minimumScore must be between zero and one")
        }
        if let drop = configuration.qualityGate.maximumScoreDrop, !(0...1).contains(drop) {
            throw ContractError.invalidConfiguration("qualityGate.maximumScoreDrop must be between zero and one")
        }
        guard configuration.qualityGate.maximumIntegrityWarnings >= 0 else {
            throw ContractError.invalidConfiguration("qualityGate.maximumIntegrityWarnings cannot be negative")
        }
        guard ["conservative", "default", "experimental", "all"].contains(configuration.operatorTier) else { throw ContractError.invalidConfiguration("operatorTier must be conservative, default, experimental, or all") }
        if configuration.operatorTier == "conservative" || configuration.operatorTier == "default" {
            throw ContractError.invalidConfiguration("No operators have enough real-package campaign data for the '\(configuration.operatorTier)' tier; all V1 operators remain experimental.")
        }
        switch configuration.project.kind {
        case .swiftPackage:
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else { throw MutationEngineError.invalidProject("No Package.swift found at \(root.path).") }
        case .xcodeProject:
            guard projectURL.pathExtension == "xcodeproj", FileManager.default.fileExists(atPath: projectURL.path), let target = configuration.project.testTarget, !target.isEmpty else { throw MutationEngineError.invalidProject("Xcode project runs require an existing .xcodeproj path and --test-target.") }
        case .xcodeWorkspace:
            guard projectURL.pathExtension == "xcworkspace", FileManager.default.fileExists(atPath: projectURL.path), let target = configuration.project.testTarget, !target.isEmpty else { throw MutationEngineError.invalidProject("Xcode workspace runs require an existing .xcworkspace path and --test-target.") }
        }
    }

    private func executionConcurrency(root: URL, projectKind: ProjectKind, requested: Int) -> Int {
        guard projectKind == .swiftPackage else { return 1 }
        let testsRoot = root.appendingPathComponent("Tests", isDirectory: true)
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: testsRoot.path))?.filter { $0.hasSuffix(".swift") } ?? []
        for path in paths {
            let file = testsRoot.appendingPathComponent(path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("import XCTest") || text.contains("XCTestCase") { return 1 }
        }
        return max(1, requested)
    }

    private func discoverSources(root: URL, requested: [String], kind: ProjectKind) throws -> [URL] {
        let manager = FileManager.default
        let paths: [String]
        if !requested.isEmpty {
            paths = requested
        } else if kind == .swiftPackage {
            paths = (try? manager.subpathsOfDirectory(atPath: root.appendingPathComponent("Sources").path))?.filter { $0.hasSuffix(".swift") }.map { "Sources/\($0)" } ?? []
        } else {
            paths = (try? manager.subpathsOfDirectory(atPath: root.path))?.filter { path in
                let components = path.split(separator: "/").map { $0.lowercased() }
                let fileBase = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
                let isTestPath = components.contains { $0 == "test" || $0 == "tests" || $0.hasSuffix("tests") }
                    || fileBase.hasSuffix("test") || fileBase.hasSuffix("tests")
                return path.hasSuffix(".swift") && !isTestPath && !path.contains("/.build/") && !path.contains("/.git/") && !path.contains("/DerivedData/") && !path.contains("/.swift-mutation-testing/")
            } ?? []
        }
        var result: [URL] = []
        for item in paths {
            let selectedURL = URL(fileURLWithPath: item, relativeTo: root).standardizedFileURL
            let path = selectedURL
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path.path, isDirectory: &isDirectory) else { throw MutationEngineError.invalidProject("Source selector does not exist: \(item)") }
            if isDirectory.boolValue {
                let nested = try manager.subpathsOfDirectory(atPath: path.path).filter { $0.hasSuffix(".swift") }
                result += nested.map { path.appendingPathComponent($0) }
            } else if path.pathExtension == "swift" { result.append(path) }
        }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return Array(Set(result.filter { $0.path.hasPrefix(rootPath) })).sorted { $0.path < $1.path }
    }

    private func relativePath(_ file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(prefix) else { return filePath }
        return String(filePath.dropFirst(prefix.count))
    }

    private func digestInputs(root: URL, files: [URL], configuration: RunConfiguration, excluding excludedPaths: [URL]) throws -> String {
        var inputs: [String: Data] = [:]
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let excludedRelativePaths = excludedPaths.compactMap { path -> String? in
            let absolute = path.standardizedFileURL.path
            return absolute.hasPrefix(rootPath) ? String(absolute.dropFirst(rootPath.count)) : nil
        }
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
            for case let file as URL in enumerator {
                let relative = relativePath(file, root: root)
                let pathComponents = relative.split(separator: "/").map(String.init)
                let isRunArtifact = excludedRelativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
                if isRunArtifact || pathComponents.contains(where: { [".git", ".build", ".swiftpm", ".swift-mutation-testing", "DerivedData"].contains($0) }) {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if let contents = try? Data(contentsOf: file) { inputs[relative] = contents }
            }
        }
        // Explicit source selections may include paths outside conventional project enumeration
        // layouts. Add them even if the enumerator filtered or skipped an unusual file type.
        for file in files { inputs[relativePath(file, root: root)] = try Data(contentsOf: file) }
        let configurationEncoder = JSONEncoder()
        configurationEncoder.outputFormatting = [.sortedKeys]
        let configData = try configurationEncoder.encode(configuration)
        var content = Data()
        for (path, data) in inputs.sorted(by: { $0.key < $1.key }) {
            content.append(contentsOf: path.utf8)
            content.append(0)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { content.append(contentsOf: $0) }
            content.append(data)
        }
        content.append(configData)
        content.append(contentsOf: "\u{0}0.1.0\u{0}swift-mutation-testing-spec-1.0.0".utf8)
        return SHA256Digest.hash(content)
    }

    private func makeSandbox(from source: URL, into parent: URL, excluding excludedPaths: [URL]) throws -> URL {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let sandbox = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let sourcePath = source.standardizedFileURL.path.hasSuffix("/") ? source.standardizedFileURL.path : source.standardizedFileURL.path + "/"
        let excludedRelativePaths = excludedPaths.compactMap { path -> String? in
            let absolute = path.standardizedFileURL.path
            return absolute.hasPrefix(sourcePath) ? String(absolute.dropFirst(sourcePath.count)) : nil
        }
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return sandbox }
        for case let file as URL in enumerator {
            let relative = relativePath(file, root: source)
            let isRunArtifact = excludedRelativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
            if isRunArtifact || relative == ".git" || relative.hasPrefix(".git/") || relative == ".build" || relative.hasPrefix(".build/") || relative == ".swiftpm" || relative.hasPrefix(".swiftpm/") || relative == ".swift-mutation-testing" || relative.hasPrefix(".swift-mutation-testing/") || relative == "DerivedData" || relative.hasPrefix("DerivedData/") {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let destination = sandbox.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }
        return sandbox
    }

    private func activationFile(for candidate: MutationCandidate, in directory: URL?, useFile: Bool) -> URL? {
        guard useFile, let directory else { return nil }
        return directory.appendingPathComponent("activation-\(candidate.id).txt")
    }

    private func activationContains(_ id: String, file: URL?, output: String) -> Bool {
        if let file, let text = try? String(contentsOf: file, encoding: .utf8),
           text.split(whereSeparator: \.isNewline).contains(Substring(id)) {
            return true
        }
        return output.contains("SWIFT_MUTATION_ACTIVATED:\(id)")
    }

    private func executedTestCount(in output: String) -> Int? {
        let pattern = #"(?:Executed|Test run with)\s+(\d+)\s+tests?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let counts = regex.matches(in: output, range: range).compactMap { match -> Int? in
            guard let capture = Range(match.range(at: 1), in: output) else { return nil }
            return Int(output[capture])
        }
        return counts.max()
    }

    private func loadJournal(at url: URL) -> [JournalEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(JournalEntry.self, from: data)
        }
    }

    private func appendJournal(_ entry: JournalEntry, to url: URL) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry) + Data([0x0a])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
