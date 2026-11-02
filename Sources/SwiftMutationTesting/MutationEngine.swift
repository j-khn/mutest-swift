import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ProjectFilePaths {
    private static let generatedDirectories: Set<String> = [
        ".git", ".build", ".build-xcode", ".swiftpm", ".swift-mutation-testing", "DerivedData"
    ]

    static func isGenerated(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        if let swiftPMIndex = components.firstIndex(of: ".swiftpm") {
            // SwiftPM's shared Xcode schemes are project configuration, not build cache.
            // Xcode needs them in the sandbox to build the selected package's test target.
            let suffix = Array(components.dropFirst(swiftPMIndex + 1))
            let sharedSchemes = ["xcode", "xcshareddata", "xcschemes"]
            let isSharedSchemePath = sharedSchemes.starts(with: suffix) || suffix.starts(with: sharedSchemes)
            if !isSharedSchemePath { return true }
        }
        return components.contains { generatedDirectories.contains($0) && $0 != ".swiftpm" }
    }
}

public enum MutationEngineError: Error, CustomStringConvertible {
    case invalidProject(String)
    case baselineFailed(log: URL, timedOut: Bool)
    case baselineBuildFailed(log: URL, timedOut: Bool)
    case baselineRanNoTests(log: URL)
    case dependencyResolutionFailed(log: URL, timedOut: Bool)
    case noSourceFiles(String)
    case invalidSelection(String)
    public var description: String {
        switch self {
        case .invalidProject(let message), .noSourceFiles(let message), .invalidSelection(let message): return message
        case .baselineFailed(let log, let timedOut): return "Baseline tests \(timedOut ? "timed out" : "failed"); no mutation score was produced. Log: \(log.path)"
        case .baselineBuildFailed(let log, let timedOut): return "Xcode test build \(timedOut ? "timed out" : "failed"); tests did not start and no mutation score was produced. Log: \(log.path)"
        case .baselineRanNoTests(let log): return "Baseline command succeeded but ran zero tests; no mutation score was produced. Check test selectors and log: \(log.path)"
        case .dependencyResolutionFailed(let log, let timedOut): return "Package dependency resolution \(timedOut ? "timed out" : "failed"); no mutation score was produced. Log: \(log.path)"
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
    private var isolatedBuildSeconds: TimeInterval = 0

    func store(_ record: MutantRecord, warning: IntegrityWarning? = nil, retry: MutationCandidate? = nil, isolatedBuildSeconds: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
        if let warning { warnings.append(warning) }
        if let retry { retries.append(retry) }
        self.isolatedBuildSeconds += isolatedBuildSeconds
    }

    func snapshot() -> (records: [String: MutantRecord], warnings: [IntegrityWarning], retries: [MutationCandidate], isolatedBuildSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (records, warnings, retries, isolatedBuildSeconds)
    }
}

private final class MutationRunMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var baselineTestCount: Int?
    private var mutantTestRunCount = 0

    func recordBaseline(testCount: Int) {
        lock.lock(); defer { lock.unlock() }
        baselineTestCount = testCount
    }

    func recordMutantTestRun() {
        lock.lock(); defer { lock.unlock() }
        mutantTestRunCount += 1
    }

    func snapshot() -> (baselineTestCount: Int?, mutantTestRunCount: Int) {
        lock.lock(); defer { lock.unlock() }
        return (baselineTestCount, mutantTestRunCount)
    }
}

/// Writes a small, live progress line to the CLI's stdout while mutant tests run.
/// Child-process output remains isolated in per-mutant log files.
private final class MutationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let generatedMutantCount: Int
    private let sourceFileCount: Int
    private let suppressedCount: Int
    private var completed: Int

    init(total: Int, generatedMutantCount: Int, sourceFileCount: Int, suppressedCount: Int, completed: Int) {
        self.total = total
        self.generatedMutantCount = generatedMutantCount
        self.sourceFileCount = sourceFileCount
        self.suppressedCount = suppressedCount
        self.completed = min(total, max(0, completed))
    }

    func announceStart() {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, total - completed)
        let line = "[mutest-swift] Scope: \(sourceFileCount) source files, \(generatedMutantCount) mutants; \(suppressedCount) suppressed, \(completed) cached, \(remaining) remaining.\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    func recordCompletion(candidate: MutationCandidate, status: MutantStatus) {
        lock.lock(); defer { lock.unlock() }
        guard total > 0 else { return }
        completed = min(total, completed + 1)
        let filename = URL(fileURLWithPath: candidate.source).lastPathComponent
        let line = "\(symbol(for: status)) \(completed)/\(total)  \(operatorName(candidate.operatorID))  \(filename):\(candidate.line)\n"
        try? FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
    }

    private func symbol(for status: MutantStatus) -> String {
        switch status {
        case .killed: "✓"
        case .survived: "✗"
        case .noCoverage: "?"
        case .timeout: "⌛"
        case .unbuildable: "⚠"
        case .suppressed: "⊘"
        }
    }

    private func operatorName(_ operatorID: MutationOperator) -> String {
        switch operatorID {
        case .relational: "RelationalOperatorReplacement"
        case .boolean: "BooleanLiteralReplacement"
        case .logical: "LogicalOperatorReplacement"
        case .arithmetic: "ArithmeticOperatorReplacement"
        case .negateConditional: "NegateConditional"
        case .swapTernary: "SwapTernary"
        case .removeSideEffects: "RemoveSideEffects"
        }
    }
}

private final class WorkerScratchPool: @unchecked Sendable {
    private let condition = NSCondition()
    private var available: [URL]

    init(scratchPaths: [URL]) {
        available = scratchPaths
    }

    func acquire() -> URL {
        condition.lock()
        defer { condition.unlock() }
        while available.isEmpty { condition.wait() }
        return available.removeFirst()
    }

    func release(_ scratchPath: URL) {
        condition.lock()
        available.append(scratchPath)
        condition.signal()
        condition.unlock()
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
    private let xcodebuildArguments: [String]
    public init(xcodebuildArguments: [String] = []) { self.xcodebuildArguments = xcodebuildArguments }

    public func run(configuration: RunConfiguration, outputDirectory: URL? = nil) throws -> MutationReport {
        let runStartedAt = Date()
        let runMetrics = MutationRunMetrics()
        let projectURL = URL(fileURLWithPath: configuration.project.path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        let root = configuration.project.kind == .swiftPackage ? projectURL : projectURL.deletingLastPathComponent()
        mutationLog("Starting \(configuration.project.kind.rawValue) mutation run.")
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
        // A failed baseline or simulator setup must never publish a previous run's score.
        for filename in ["report.json", "report.md", "stryker.json"] {
            let previous = output.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        }
        var timings = MutationTimings()
        if configuration.project.kind != .swiftPackage {
            mutationLog("Resolving Xcode simulator destination…")
        }
        let simulatorTemplate = configuration.project.kind == .swiftPackage ? nil : try XcodeSimulatorTemplate.load(destination: configuration.project.destination, logs: logs)
        mutationLog("Discovering package dependencies…")
        let dependencyDiscoveryStarted = Date()
        let dependencyGraph = try PackageDependencyResolver.discover(
            projectURL: projectURL,
            projectRoot: root,
            kind: configuration.project.kind,
            logs: logs,
            timeout: TimeInterval(configuration.timeouts.buildSeconds)
        )
        mutationLog("Dependency manifests inspected in \(String(format: "%.1f", Date().timeIntervalSince(dependencyDiscoveryStarted)))s.")
        let sandboxCopyStarted = Date()
        mutationLog("Creating isolated project sandbox…")
        let sandboxLayout = try makeSandbox(
            from: root,
            localPackageRoots: dependencyGraph.localPackages,
            into: output.appendingPathComponent("sandboxes", isDirectory: true),
            excluding: [output] + (cacheDirectory.map { [$0] } ?? [])
        )
        let sandbox = sandboxLayout.root
        timings.sandboxCopySeconds = Date().timeIntervalSince(sandboxCopyStarted)
        mutationLog("Project sandbox ready in \(String(format: "%.1f", timings.sandboxCopySeconds))s.")
        var auxiliarySandboxContainers: [URL] = []
        var sandboxRemoved = false
        defer {
            if !sandboxRemoved {
                auxiliarySandboxContainers.forEach { try? FileManager.default.removeItem(at: $0) }
                try? FileManager.default.removeItem(at: sandboxLayout.container)
            }
        }
        let testDiscoveryStarted = Date()
        mutationLog("Discovering selected tests…")
        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: configuration.tests,
            testTarget: configuration.project.testTarget,
            forXcode: configuration.project.kind != .swiftPackage
        )
        timings.testDiscoverySeconds = Date().timeIntervalSince(testDiscoveryStarted)
        mutationLog("Test discovery complete: \(selection.identifiers.count) selected test identifiers\(selection.allTests ? " (full target)" : "").")
        let xcodeBuildWorkspace = configuration.project.kind == .swiftPackage ? nil : try XcodeBuildWorkspace()
        defer { xcodeBuildWorkspace?.cleanup() }
        let adapter = NativeTestAdapter(project: adapterProject, selection: configuration.tests, xcodebuildArguments: xcodebuildArguments, xcodeDerivedDataPath: xcodeBuildWorkspace?.derivedData)
        let runner = ProcessRunner()
        mutationLog("Resolving package dependencies…")
        let dependencyResolutionStarted = Date()
        let dependencyLog = logs.appendingPathComponent("dependency-resolution.log")
        let dependencyCommand = try adapter.command(
            root: sandbox,
            phase: .resolveDependencies,
            resolved: selection,
            environment: [:],
            timeout: TimeInterval(configuration.timeouts.buildSeconds),
            output: dependencyLog,
            xcodeContext: xcodeBuildWorkspace.map {
                .init(destination: configuration.project.destination ?? "", derivedDataPath: $0.derivedData)
            }
        )
        let dependencyResult = try runner.run(dependencyCommand)
        guard !dependencyResult.timedOut, dependencyResult.exitCode == 0 else {
            throw MutationEngineError.dependencyResolutionFailed(log: dependencyLog, timedOut: dependencyResult.timedOut)
        }
        mutationLog("Package dependencies resolved in \(String(format: "%.1f", Date().timeIntervalSince(dependencyResolutionStarted)))s.")
        let baselineLog = logs.appendingPathComponent("baseline.log")
        var baselineValidated = false
        var mutationPhaseStarted: Date?
        func validateBaseline(phase: TestPhase) throws {
            let baselineStarted = Date()
            mutationLog("Running baseline tests…")
            let command = try adapter.command(root: sandbox, phase: phase, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.baselineSeconds), output: baselineLog)
            let baseline = try runner.run(command)
            timings.baselineSeconds += Date().timeIntervalSince(baselineStarted)
            guard !baseline.timedOut && baseline.exitCode == 0 else {
                appendBaselineFailureDetails(command: command, result: baseline, originalProject: root, to: baselineLog)
                if !baseline.timedOut,
                   configuration.project.kind == .swiftPackage,
                   baseline.output.trimmingCharacters(in: .whitespacesAndNewlines) == "error: fatalError" {
                    appendVerboseSwiftPMBuildDiagnostics(
                        adapter: adapter,
                        root: sandbox,
                        selection: selection,
                        timeout: TimeInterval(configuration.timeouts.buildSeconds),
                        runner: runner,
                        to: baselineLog
                    )
                }
                throw MutationEngineError.baselineFailed(log: baselineLog, timedOut: baseline.timedOut)
            }
            guard let baselineTestCount = executedTestCount(in: baseline.output), baselineTestCount > 0 else {
                throw MutationEngineError.baselineRanNoTests(log: baselineLog)
            }
            runMetrics.recordBaseline(testCount: baselineTestCount)
            baselineValidated = true
            mutationPhaseStarted = Date()
        }

        let sourceDiscoveryStarted = Date()
        mutationLog("Discovering mutation source files…")
        let sourceFiles = try discoverSources(root: root, requested: configuration.source, kind: configuration.project.kind,
            excluding: [output] + (cacheDirectory.map { [$0] } ?? []))
        guard !sourceFiles.isEmpty else { throw MutationEngineError.noSourceFiles("No Swift source files found in the selected source scope.") }
        var candidates: [MutationCandidate] = []
        let generator = SwiftMutationGenerator()
        for file in sourceFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let relative = relativePath(file, root: root)
            candidates += generator.generate(source: contents, relativePath: relative, operators: Set(configuration.operators), suppression: configuration.suppression)
        }
        candidates.sort { ($0.source, $0.span.start) < ($1.source, $1.span.start) }
        timings.sourceDiscoverySeconds = Date().timeIntervalSince(sourceDiscoveryStarted)
        mutationLog("Mutation discovery complete: \(sourceFiles.count) source files, \(candidates.count) candidates.")

        var digestConfiguration = configuration
        digestConfiguration.project.path = configuration.project.kind == .swiftPackage ? "." : adapterProject.path
        digestConfiguration.cache = .init(enabled: true)
        digestConfiguration.resume = true
        digestConfiguration.qualityGate = .init()
        digestConfiguration.output = .init()
        let journalDirectory = cacheDirectory ?? output
        let inputHashStarted = Date()
        let dependencyInputs = packageDependencyInputFiles(graph: dependencyGraph, projectRoot: root)
            + resolvedDependencyInputFiles(in: sandboxLayout)
        let inputDigest = try digestInputs(root: root, files: sourceFiles, configuration: digestConfiguration, xcodebuildArguments: xcodebuildArguments, excluding: [output, journalDirectory], runtimeFingerprint: simulatorTemplate?.fingerprint ?? "", additionalFiles: dependencyInputs)
        timings.inputHashSeconds = Date().timeIntervalSince(inputHashStarted)
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
        let progress = MutationProgress(
            total: runnable.count,
            generatedMutantCount: candidates.count,
            sourceFileCount: Set(sourceFiles.map { relativePath($0, root: root) }).count,
            suppressedCount: candidates.count - runnable.count,
            completed: runnable.filter { records[$0.id] != nil }.count
        )
        progress.announceStart()
        var historicalDurations: [String: TimeInterval] = [:]
        for entry in cached {
            if let duration = entry.record.durationSeconds { historicalDurations[entry.record.id] = duration }
        }
        func slowestFirst(_ lhs: MutationCandidate, _ rhs: MutationCandidate) -> Bool {
            let left = historicalDurations[lhs.id] ?? 0
            let right = historicalDurations[rhs.id] ?? 0
            return left == right ? lhs.id < rhs.id : left > right
        }

        var xcodeExecution: XcodeMutationExecutionResult?
        if let simulatorTemplate {
            let sources = Dictionary(uniqueKeysWithValues: try sourceFiles.map { file in
                (relativePath(file, root: root), try String(contentsOf: file, encoding: .utf8))
            })
            let lockedJournal = configuration.cache.enabled ? LockedJournal(url: journal) : nil
            let executor = XcodeMutationExecutor(configuration: configuration, adapter: adapter, selection: selection,
                sandbox: sandbox, output: output, sources: sources, buildWorkspace: xcodeBuildWorkspace,
                createSandbox: { try self.makeSandbox(from: sandbox, localPackageRoots: sandboxLayout.localPackages, into: output.appendingPathComponent("sandboxes/isolated-workers"), excluding: []) },
                onVerdict: { record, warnings in
                    try lockedJournal?.append(.init(cacheKey: inputDigest + ":" + record.id, record: record, warnings: warnings))
                }, onCompletion: { candidate, status in progress.recordCompletion(candidate: candidate, status: status) })
            let completed = try executor.run(template: simulatorTemplate, candidates: remaining, historicalDurations: historicalDurations)
            xcodeExecution = completed
            records.merge(completed.records) { _, new in new }
            warnings += completed.warnings
            timings.baselineSeconds += completed.timings.baselineSeconds
            timings.schemaBuildSeconds += completed.timings.schemaBuildSeconds
            timings.mutantRunSeconds += completed.timings.mutantRunSeconds
            timings.isolatedBuildSeconds += completed.timings.isolatedBuildSeconds
            timings.cleanupSeconds += completed.timings.cleanupSeconds
            baselineValidated = true
        } else if !remaining.isEmpty {
            let sourceByRelative = Dictionary(uniqueKeysWithValues: sourceFiles.map { (relativePath($0, root: root), $0) })
            var candidatesBySource: [String: [MutationCandidate]] = [:]
            for item in remaining { candidatesBySource[item.source, default: []].append(item) }

            // Build one schema containing all non-overlapping mutations. The runtime switch
            // activates exactly one ID for each test invocation and writes an activation marker.
            var schemaCandidates: [MutationCandidate] = []
            var isolatedCandidates: [MutationCandidate] = []
            var schemaBuildFailed = false
            let activationDirectory: URL? = configuration.project.kind == .swiftPackage ? logs : nil
            for (relative, items) in candidatesBySource {
                let original = try String(contentsOf: sourceByRelative[relative]!, encoding: .utf8)
                // Safe statement-form rewrites can share a schema. The generator marks
                // single-item code blocks for isolation because Swift may infer an implicit
                // return from their final expression.
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
                let schemaBuildStarted = Date()
                let build = try runner.run(buildCommand)
                timings.schemaBuildSeconds += Date().timeIntervalSince(schemaBuildStarted)
                if build.timedOut || build.exitCode != 0 {
                    // Retry smaller compatible groups after validating the original baseline.
                    // This keeps one bad rewrite from forcing every schema member into isolation.
                    schemaBuildFailed = true
                    for original in sourceFiles {
                        let relative = relativePath(original, root: root)
                        let clean = try String(contentsOf: original, encoding: .utf8)
                        try clean.write(to: sandbox.appendingPathComponent(relative), atomically: true, encoding: .utf8)
                    }
                } else {
                    // The schema build has already compiled the inactive/original path. Run
                    // the full baseline against that exact binary, then reuse it for mutants.
                    try validateBaseline(phase: .testWithoutBuilding)
                    let concurrency = executionConcurrency(
                        root: root,
                        projectKind: configuration.project.kind,
                        requested: configuration.parallelism,
                        candidateCount: schemaCandidates.count
                    )
                    let workerScratchPool = try makeWorkerScratchPool(
                        sandbox: sandbox,
                        projectKind: configuration.project.kind,
                        workerCount: concurrency
                    )
                    let parallelResults = MutationRunResults()
                    let lockedJournal = configuration.cache.enabled ? LockedJournal(url: journal) : nil
                    let currentActivationDirectory = activationDirectory
                    let queue = OperationQueue()
                    queue.name = "swift-mutation-testing.mutants"
                    queue.maxConcurrentOperationCount = concurrency
                    for candidate in schemaCandidates.filter({ records[$0.id] == nil }).sorted(by: slowestFirst) {
                        queue.addOperation {
                            var waitingForRetry = false
                            var progressStatus = MutantStatus.unbuildable
                            defer {
                                if !waitingForRetry {
                                    progress.recordCompletion(candidate: candidate, status: progressStatus)
                                }
                            }
                            let workerScratch = workerScratchPool?.acquire()
                            defer {
                                if let workerScratch { workerScratchPool?.release(workerScratch) }
                            }
                            do {
                                let cacheKey = inputDigest + ":" + candidate.id
                                let activation = self.activationFile(for: candidate, in: currentActivationDirectory, useFile: currentActivationDirectory != nil)
                                if let activation { try? FileManager.default.removeItem(at: activation) }
                                var env = ["SWIFT_MUTATION_ID": candidate.id]
                                if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                                let log = logs.appendingPathComponent("mutant-\(candidate.id).log")
                                let command = try adapter.command(
                                    root: sandbox,
                                    phase: .testWithoutBuilding,
                                    resolved: selection,
                                    environment: env,
                                    timeout: TimeInterval(configuration.timeouts.mutantSeconds),
                                    output: log,
                                    scratchPath: workerScratch,
                                    stopOnActivatedTestFailure: true,
                                    activationID: candidate.id,
                                    activationFile: activation
                                )
                                runMetrics.recordMutantTestRun()
                                let result = try runner.run(command)
                                let activated = self.activationContains(candidate.id, file: activation, output: result.output)
                                var record = candidate.record
                                record.durationSeconds = result.elapsed
                                record.activated = activated
                                if result.timedOut { record.status = .timeout }
                                else if !activated { record.status = .noCoverage }
                                else { record.status = result.exitCode == 0 ? .survived : .killed }
                                progressStatus = record.status
                                if result.stoppedEarly { record.message = "Stopped after a selected test failed while this mutant was active." }
                                // An activation marker proves at least one selected test reached
                                // the mutated code. A killed mutant may stop before Swift Testing
                                // prints its final executed-test count, so do not flag it as a
                                // zero-test run merely because that summary is absent.
                                let warning: IntegrityWarning? = executedTestCount(in: result.output) == 0 && !result.stoppedEarly && !activated
                                    ? .init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id)
                                    : (!activated && result.exitCode != 0 && !result.timedOut
                                        ? .init(code: "testsFailedWithoutActivation", message: "Test execution failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id)
                                        : nil)
                                let retry = result.timedOut && concurrency > 1 && configuration.timeouts.parallelRetry ? candidate : nil
                                waitingForRetry = retry != nil
                                parallelResults.store(record, warning: warning, retry: retry)
                                try lockedJournal?.append(.init(cacheKey: cacheKey, record: record, warnings: warning.map { [$0] } ?? []))
                            } catch {
                                var record = candidate.record
                                record.status = .unbuildable
                                record.message = "Could not execute mutant: \(error)"
                                progressStatus = record.status
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
                        let retryScratch = workerScratchPool?.acquire()
                        defer {
                            if let retryScratch { workerScratchPool?.release(retryScratch) }
                        }
                        let activation = activationFile(for: candidate, in: activationDirectory, useFile: activationDirectory != nil)
                        if let activation { try? FileManager.default.removeItem(at: activation) }
                        var env = ["SWIFT_MUTATION_ID": candidate.id]
                        if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                        let log = logs.appendingPathComponent("retry-isolated-\(candidate.id).log")
                        let retryTimeout = TimeInterval(configuration.timeouts.mutantSeconds) * configuration.timeouts.retryMultiplier
                        let command = try adapter.command(root: sandbox, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: retryTimeout, output: log, scratchPath: retryScratch, stopOnActivatedTestFailure: true, activationID: candidate.id, activationFile: activation)
                        runMetrics.recordMutantTestRun()
                        let result = try runner.run(command)
                        let activated = activationContains(candidate.id, file: activation, output: result.output)
                        var record = records[candidate.id] ?? candidate.record
                        record.durationSeconds = (record.durationSeconds ?? 0) + result.elapsed
                        record.activated = activated
                        record.message = "Timed out during parallel execution; retried in isolation with a \(configuration.timeouts.retryMultiplier)x mutant timeout."
                        if result.timedOut { record.status = .timeout }
                        else if !activated { record.status = .noCoverage }
                        else { record.status = result.exitCode == 0 ? .survived : .killed }
                        if result.stoppedEarly { record.message = (record.message ?? "") + " Stopped after an activated test failure." }
                        var retryWarnings: [IntegrityWarning] = []
                        if executedTestCount(in: result.output) == 0 && !result.stoppedEarly && !activated {
                            retryWarnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id))
                        } else if !activated && result.exitCode != 0 && !result.timedOut {
                            retryWarnings.append(.init(code: "testsFailedWithoutActivation", message: "Isolated retry failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id))
                        }
                        warnings += retryWarnings
                        records[candidate.id] = record
                        if configuration.cache.enabled {
                            try appendJournal(.init(cacheKey: inputDigest + ":" + candidate.id, record: record, warnings: retryWarnings), to: journal)
                        }
                        progress.recordCompletion(candidate: candidate, status: record.status)
                    }
                }
            }

            if !baselineValidated {
                try validateBaseline(phase: .baseline)
            }

            if schemaBuildFailed {
                func runSchemaBatch(_ batch: [MutationCandidate]) throws {
                    guard !batch.isEmpty else { return }
                    var batchBySource: [String: [MutationCandidate]] = [:]
                    for candidate in batch { batchBySource[candidate.source, default: []].append(candidate) }
                    for sourceFile in sourceFiles {
                        let relative = relativePath(sourceFile, root: root)
                        let original = try String(contentsOf: sourceFile, encoding: .utf8)
                        let sourceCandidates = batchBySource[relative] ?? []
                        let schema = generator.makeSchema(source: original, candidates: sourceCandidates)
                        isolatedCandidates += schema.isolated
                        try schema.source.write(to: sandbox.appendingPathComponent(relative), atomically: true, encoding: .utf8)
                    }

                    let batchID = String(SHA256Digest.hash(batch.map(\.id).joined(separator: ":")).prefix(12))
                    let buildLog = logs.appendingPathComponent("schema-narrowed-build-\(batchID).log")
                    let buildStarted = Date()
                    let build = try runner.run(adapter.command(root: sandbox, phase: .buildForTesting, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.buildSeconds), output: buildLog))
                    timings.schemaBuildSeconds += Date().timeIntervalSince(buildStarted)
                    if build.timedOut || build.exitCode != 0 {
                        if batch.count == 1 {
                            isolatedCandidates.append(batch[0])
                            return
                        }
                        let midpoint = batch.count / 2
                        try runSchemaBatch(Array(batch[..<midpoint]))
                        try runSchemaBatch(Array(batch[midpoint...]))
                        return
                    }

                    for candidate in batch.sorted(by: slowestFirst) {
                        let activation = activationFile(for: candidate, in: activationDirectory, useFile: activationDirectory != nil)
                        if let activation { try? FileManager.default.removeItem(at: activation) }
                        var env = ["SWIFT_MUTATION_ID": candidate.id]
                        if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                        let log = logs.appendingPathComponent("mutant-\(candidate.id).log")
                        runMetrics.recordMutantTestRun()
                        let result = try runner.run(adapter.command(root: sandbox, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: TimeInterval(configuration.timeouts.mutantSeconds), output: log, stopOnActivatedTestFailure: true, activationID: candidate.id, activationFile: activation))
                        let activated = activationContains(candidate.id, file: activation, output: result.output)
                        var record = candidate.record
                        record.durationSeconds = result.elapsed
                        record.activated = activated
                        if result.timedOut { record.status = .timeout }
                        else if !activated { record.status = .noCoverage }
                        else { record.status = result.exitCode == 0 ? .survived : .killed }
                        if result.stoppedEarly { record.message = "Stopped after a selected test failed while this mutant was active." }
                        var mutantWarnings: [IntegrityWarning] = []
                        if executedTestCount(in: result.output) == 0 && !result.stoppedEarly && !activated {
                            mutantWarnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id))
                        } else if !activated && result.exitCode != 0 && !result.timedOut {
                            mutantWarnings.append(.init(code: "testsFailedWithoutActivation", message: "Test execution failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id))
                        }
                        warnings += mutantWarnings
                        records[candidate.id] = record
                        if configuration.cache.enabled {
                            try appendJournal(.init(cacheKey: inputDigest + ":" + candidate.id, record: record, warnings: mutantWarnings), to: journal)
                        }
                        progress.recordCompletion(candidate: candidate, status: record.status)
                    }
                }
                try runSchemaBatch(schemaCandidates.sorted(by: slowestFirst))
            }

            let runnableIsolated = isolatedCandidates.filter { records[$0.id] == nil }.sorted(by: slowestFirst)
            if !runnableIsolated.isEmpty {
                let requestedWorkers = executionConcurrency(root: root, projectKind: configuration.project.kind, requested: configuration.parallelism, candidateCount: runnableIsolated.count)
                let workerCount = min(requestedWorkers, runnableIsolated.count)
                var workerRoots: [URL] = []
                if workerCount > 1 {
                    let workerCopyStarted = Date()
                    for _ in 0..<workerCount {
                        let worker = try makeSandbox(
                            from: sandbox,
                            localPackageRoots: sandboxLayout.localPackages,
                            into: output.appendingPathComponent("sandboxes/isolated-workers", isDirectory: true),
                            excluding: []
                        )
                        // These sandboxes have distinct package roots and therefore need distinct
                        // SwiftPM build databases. Reusing a copied .build directory can retain
                        // absolute paths from the source sandbox and produce stale products.
                        // Each worker's first mutant build warms its own scratch directory.
                        for sourceFile in sourceFiles {
                            let relative = relativePath(sourceFile, root: root)
                            let clean = try String(contentsOf: sourceFile, encoding: .utf8)
                            try clean.write(to: worker.root.appendingPathComponent(relative), atomically: true, encoding: .utf8)
                        }
                        workerRoots.append(worker.root)
                        auxiliarySandboxContainers.append(worker.container)
                    }
                    timings.sandboxCopySeconds += Date().timeIntervalSince(workerCopyStarted)
                } else {
                    workerRoots = [sandbox]
                }
                let workerPool = WorkerScratchPool(scratchPaths: workerRoots)
                let isolatedResults = MutationRunResults()
                let lockedJournal = configuration.cache.enabled ? LockedJournal(url: journal) : nil
                let queue = OperationQueue()
                queue.name = "mutest-swift.isolated-mutants"
                queue.maxConcurrentOperationCount = workerCount
                for candidate in runnableIsolated {
                    queue.addOperation {
                        let workerRoot = workerPool.acquire()
                        var progressStatus = MutantStatus.unbuildable
                        defer {
                            workerPool.release(workerRoot)
                            progress.recordCompletion(candidate: candidate, status: progressStatus)
                        }
                        let original = try? String(contentsOf: sourceByRelative[candidate.source]!, encoding: .utf8)
                        let relativeFile = workerRoot.appendingPathComponent(candidate.source)
                        defer {
                            if let original { try? original.write(to: relativeFile, atomically: true, encoding: .utf8) }
                        }
                        do {
                            guard let original else { throw MutationEngineError.invalidProject("Could not read original source for \(candidate.source).") }
                            let mutantSource = generator.makeIsolatedSchema(source: original, candidate: candidate)
                            try mutantSource.write(to: relativeFile, atomically: true, encoding: .utf8)
                            let log = logs.appendingPathComponent("isolated-\(candidate.id).log")
                            let buildLog = logs.appendingPathComponent("isolated-build-\(candidate.id).log")
                            let build = try runner.run(adapter.command(root: workerRoot, phase: .buildForTesting, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.buildSeconds), output: buildLog))
                            var record = candidate.record
                            record.durationSeconds = build.elapsed
                            if build.timedOut {
                                record.status = .unbuildable
                                record.message = "Isolated mutant build timed out after \(configuration.timeouts.buildSeconds) seconds; see \(buildLog.path)."
                            } else if build.exitCode != 0 {
                                record.status = .unbuildable
                                record.message = "Isolated mutant did not compile; see \(buildLog.path)."
                            } else {
                                let activation = self.activationFile(for: candidate, in: activationDirectory, useFile: activationDirectory != nil)
                                if let activation { try? FileManager.default.removeItem(at: activation) }
                                var env = ["SWIFT_MUTATION_ID": candidate.id]
                                if let activation { env["SWIFT_MUTATION_ACTIVATION_FILE"] = activation.path }
                                runMetrics.recordMutantTestRun()
                                let result = try runner.run(adapter.command(root: workerRoot, phase: .testWithoutBuilding, resolved: selection, environment: env, timeout: TimeInterval(configuration.timeouts.mutantSeconds), output: log, stopOnActivatedTestFailure: true, activationID: candidate.id, activationFile: activation))
                                let wasActivated = self.activationContains(candidate.id, file: activation, output: result.output)
                                record.durationSeconds = (record.durationSeconds ?? 0) + result.elapsed
                                record.activated = wasActivated
                                if result.timedOut { record.status = .timeout }
                                else if !wasActivated { record.status = .noCoverage }
                                else { record.status = result.exitCode == 0 ? .survived : .killed }
                                progressStatus = record.status
                                var mutantWarnings: [IntegrityWarning] = []
                                if executedTestCount(in: result.output) == 0 && !result.stoppedEarly && !wasActivated {
                                    mutantWarnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero executed tests.", mutantId: candidate.id))
                                } else if !wasActivated && result.exitCode != 0 && !result.timedOut {
                                    mutantWarnings.append(.init(code: "testsFailedWithoutActivation", message: "Test execution failed but the mutation was not activated; verdict is noCoverage.", mutantId: candidate.id))
                                }
                                if result.stoppedEarly { record.message = "Stopped after a selected test failed while this mutant was active." }
                                isolatedResults.store(record, warning: mutantWarnings.first, isolatedBuildSeconds: build.elapsed)
                                if configuration.cache.enabled {
                                    try lockedJournal?.append(.init(cacheKey: inputDigest + ":" + candidate.id, record: record, warnings: mutantWarnings))
                                }
                                return
                            }
                            isolatedResults.store(record, isolatedBuildSeconds: build.elapsed)
                            if configuration.cache.enabled {
                                try lockedJournal?.append(.init(cacheKey: inputDigest + ":" + candidate.id, record: record))
                            }
                        } catch {
                            var record = candidate.record
                            record.status = .unbuildable
                            record.message = "Could not execute isolated mutant: \(error)"
                            progressStatus = record.status
                            isolatedResults.store(record, warning: .init(code: "mutantExecutionFailed", message: String(describing: error), mutantId: candidate.id))
                        }
                    }
                }
                queue.waitUntilAllOperationsAreFinished()
                if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
                let completed = isolatedResults.snapshot()
                records.merge(completed.records) { _, new in new }
                warnings += completed.warnings
                timings.isolatedBuildSeconds += completed.isolatedBuildSeconds
            }
        }
        if !baselineValidated { try validateBaseline(phase: .baseline) }
        if let mutationPhaseStarted { timings.mutantRunSeconds = Date().timeIntervalSince(mutationPhaseStarted) }

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
        let cleanupStarted = Date()
        auxiliarySandboxContainers.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.removeItem(at: sandboxLayout.container)
        sandboxRemoved = true
        timings.cleanupSeconds += Date().timeIntervalSince(cleanupStarted)
        let report = MutationReport(scope: .init(sources: selectedSources, tests: selection.identifiers, allTests: selection.allTests), mutants: orderedRecords, integrityWarnings: warnings, qualityGate: gate, timings: timings)
        let runMetricsSnapshot = runMetrics.snapshot()
        let runDetails = MutationRunSummaryDetails(
            testTarget: configuration.project.testTarget,
            baselineTestCount: xcodeExecution?.baselineCounts.first ?? runMetricsSnapshot.baselineTestCount,
            mutantTestRunCount: xcodeExecution?.mutantTestRunCount ?? runMetricsSnapshot.mutantTestRunCount,
            totalDurationSeconds: Date().timeIntervalSince(runStartedAt),
            requestedWorkerCount: configuration.parallelism,
            activeWorkerCount: xcodeExecution?.workerCount ?? executionConcurrency(root: root, projectKind: configuration.project.kind, requested: configuration.parallelism, candidateCount: remaining.count),
            baselineRunCount: xcodeExecution?.baselineCounts.count ?? 1,
            baselineTestExecutionCount: xcodeExecution?.baselineCounts.reduce(0, +) ?? runMetricsSnapshot.baselineTestCount,
            mutantTestCaseExecutionCount: xcodeExecution?.mutantTestCaseExecutionCount,
            mutantTestRunCountWithoutReportedCaseCount: xcodeExecution?.mutantTestRunCountWithoutReportedCaseCount ?? 0,
            mutantTestRuns: xcodeExecution?.mutantTestRuns ?? [],
            simulatorSetupSeconds: xcodeExecution?.simulatorSetupSeconds ?? 0
        )
        try MutationReportWriter.write(report, to: output, formats: Set(configuration.output.formats), runDetails: runDetails)
        return report
    }

    private func validate(configuration: RunConfiguration, root: URL, projectURL: URL) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { throw MutationEngineError.invalidProject("Project path does not exist: \(root.path)") }
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

    private func appendBaselineFailureDetails(command: CommandSpec, result: CommandResult, originalProject: URL, to log: URL) {
        let outcome = result.timedOut ? "timed out" : "exited with status \(result.exitCode)"
        let commandLine = ([command.executable] + command.arguments).map { argument in
            "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
        var details = "\n\n--- mutest-swift baseline failure details ---\n"
        details += "Result: \(outcome)\n"
        details += "Elapsed: \(String(format: "%.2f", result.elapsed))s\n"
        details += "Original project: \(originalProject.path)\n"
        details += "Isolated working directory: \(command.workingDirectory.path)\n"
        details += "Command: \(commandLine)\n"
        if result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "error: fatalError" {
            details += "The test command emitted only the generic 'error: fatalError' message; it provided no test name, source location, or additional output.\n"
        }
        appendLogText(details, to: log)
    }

    private func appendVerboseSwiftPMBuildDiagnostics(
        adapter: NativeTestAdapter,
        root: URL,
        selection: ResolvedTestSelection,
        timeout: TimeInterval,
        runner: ProcessRunner,
        to log: URL
    ) {
        let diagnosticLog = log.deletingLastPathComponent().appendingPathComponent("baseline-diagnostics.tmp")
        defer { try? FileManager.default.removeItem(at: diagnosticLog) }
        do {
            var command = try adapter.command(
                root: root,
                phase: .buildForTesting,
                resolved: selection,
                environment: [:],
                timeout: timeout,
                output: diagnosticLog
            )
            command.arguments.append("-v")
            let result = try runner.run(command)
            let compilerDiagnostics = Self.compilerDiagnostics(from: result.output)
            let details: String
            if !compilerDiagnostics.isEmpty {
                details = "\n--- Verbose SwiftPM build diagnostics ---\n\(compilerDiagnostics)\n"
            } else {
                let status = result.timedOut ? "timed out" : "exited with status \(result.exitCode)"
                details = "\n--- Verbose SwiftPM build diagnostics ---\nThe diagnostic build \(status) but emitted no compiler error details. The baseline failure may have occurred while launching or running tests.\n"
            }
            appendLogText(details, to: log)
        } catch {
            appendLogText("\n--- Verbose SwiftPM build diagnostics ---\nCould not run the diagnostic build: \(error)\n", to: log)
        }
    }

    private static func compilerDiagnostics(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        var selected: [String] = []
        var seen = Set<String>()
        for index in lines.indices where lines[index].contains("error:") {
            let end = min(lines.count - 1, index + 4)
            for contextIndex in index...end {
                let line = lines[contextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, seen.insert(line).inserted else { continue }
                selected.append(line.count > 1_000 ? String(line.prefix(1_000)) + "…" : line)
                if selected.joined(separator: "\n").count > 8_000 { break }
            }
            if selected.joined(separator: "\n").count > 8_000 { break }
        }
        return selected.joined(separator: "\n")
    }

    private func appendLogText(_ text: String, to log: URL) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // Keep the original baseline output intact if diagnostic details cannot be appended.
        }
    }

    private func executionConcurrency(root: URL, projectKind: ProjectKind, requested: Int, candidateCount: Int) -> Int {
        guard projectKind == .swiftPackage else { return 1 }
        let testsRoot = root.appendingPathComponent("Tests", isDirectory: true)
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: testsRoot.path))?.filter { $0.hasSuffix(".swift") } ?? []
        for path in paths {
            let file = testsRoot.appendingPathComponent(path)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("import XCTest") || text.contains("XCTestCase") { return 1 }
        }
        return min(max(1, requested), max(1, candidateCount))
    }

    private func makeWorkerScratchPool(sandbox: URL, projectKind: ProjectKind, workerCount: Int) throws -> WorkerScratchPool? {
        guard projectKind == .swiftPackage, workerCount > 1 else { return nil }
        let buildDirectory = sandbox.appendingPathComponent(".build", isDirectory: true)
        guard FileManager.default.fileExists(atPath: buildDirectory.path) else {
            throw MutationEngineError.invalidProject("SwiftPM completed its schema build without producing .build; worker isolation cannot continue.")
        }
        let workerDirectory = sandbox
            .appendingPathComponent(".swift-mutation-testing", isDirectory: true)
            .appendingPathComponent("worker-builds", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        var scratchPaths: [URL] = []
        for index in 0..<workerCount {
            let destination = workerDirectory.appendingPathComponent("worker-\(index)", isDirectory: true)
            try cloneBuildDirectory(from: buildDirectory, to: destination)
            scratchPaths.append(destination)
        }
        return WorkerScratchPool(scratchPaths: scratchPaths)
    }

    private func cloneBuildDirectory(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        if result == 0 { return }
        try? FileManager.default.removeItem(at: destination)
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func discoverSources(root: URL, requested: [String], kind: ProjectKind, excluding excludedPaths: [URL] = []) throws -> [URL] {
        let manager = FileManager.default
        let root = root.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let excludedRoots = excludedPaths.map { $0.standardizedFileURL.path }
        func isExcluded(_ file: URL) -> Bool {
            let path = file.standardizedFileURL.path
            let relative = path == root.path ? "" : relativePath(file, root: root)
            return ProjectFilePaths.isGenerated(relative)
                || excludedRoots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        func isTestPath(_ file: URL) -> Bool {
            guard file.standardizedFileURL.path != root.path else { return false }
            let relative = relativePath(file, root: root)
            return relative.split(separator: "/").contains {
                let component = $0.lowercased()
                return component == "test" || component == "tests" || component.hasSuffix("tests")
            } || file.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("test")
                || file.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("tests")
        }
        func isSource(_ file: URL) -> Bool {
            let name = file.lastPathComponent
            return file.pathExtension == "swift" && name != "Package.swift" && !name.hasPrefix("Package@swift-")
                && !isExcluded(file) && !isTestPath(file)
        }

        let paths = requested.isEmpty ? (kind == .swiftPackage ? ["Sources"] : ["."]) : requested
        var result: [URL] = []
        for item in paths {
            let path = URL(fileURLWithPath: item, relativeTo: root).standardizedFileURL
            guard path.path == root.path || path.path.hasPrefix(rootPrefix) else {
                throw MutationEngineError.invalidProject("Source selector must be inside the project: \(item)")
            }
            guard !isExcluded(path) else {
                throw MutationEngineError.invalidProject("Source selector points into generated output or a build/cache directory: \(item)")
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                if requested.isEmpty && kind == .swiftPackage { continue }
                throw MutationEngineError.invalidProject("Source selector does not exist: \(item)")
            }
            if isDirectory.boolValue {
                guard !isTestPath(path), let enumerator = manager.enumerator(at: path, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for case let file as URL in enumerator {
                    if isExcluded(file) || isTestPath(file) {
                        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                        continue
                    }
                    if isSource(file) { result.append(file.standardizedFileURL) }
                }
            } else if isSource(path) { result.append(path) }
        }
        return Array(Set(result)).sorted { $0.path < $1.path }
    }

    private func relativePath(_ file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(prefix) else { return filePath }
        return String(filePath.dropFirst(prefix.count))
    }

    private func digestInputs(root: URL, files: [URL], configuration: RunConfiguration, xcodebuildArguments: [String], excluding excludedPaths: [URL], runtimeFingerprint: String = "", additionalFiles: [(String, URL)] = []) throws -> String {
        var inputs: [String: URL] = [:]
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let excludedRelativePaths = excludedPaths.compactMap { path -> String? in
            let absolute = path.standardizedFileURL.path
            return absolute.hasPrefix(rootPath) ? String(absolute.dropFirst(rootPath.count)) : nil
        }
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
            for case let file as URL in enumerator {
                let relative = relativePath(file, root: root)
                let isRunArtifact = excludedRelativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
                if isRunArtifact || ProjectFilePaths.isGenerated(relative) {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                inputs[relative] = file
            }
        }
        // Explicit source selections may include paths outside conventional project enumeration
        // layouts. Add them even if the enumerator filtered or skipped an unusual file type.
        for file in files { inputs[relativePath(file, root: root)] = file }
        for (stablePath, file) in additionalFiles where FileManager.default.fileExists(atPath: file.path) {
            inputs[stablePath] = file
        }
        let configurationEncoder = JSONEncoder()
        configurationEncoder.outputFormatting = [.sortedKeys]
        let configData = try configurationEncoder.encode(configuration)
        var content = Data()
        let orderedInputs = inputs.sorted(by: { $0.key < $1.key })
        let estimatedBytes = orderedInputs.reduce(Int64(0)) { total, item in
            total + Int64((try? item.value.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        mutationLog("Hashing project inputs: \(orderedInputs.count) files (\(ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))).")
        for (index, item) in orderedInputs.enumerated() {
            let (path, file) = item
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            let fileDigest = SHA256Digest.hash(data)
            content.append(contentsOf: path.utf8)
            content.append(0)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { content.append(contentsOf: $0) }
            content.append(contentsOf: fileDigest.utf8)
            if (index + 1).isMultiple(of: 250) || index + 1 == orderedInputs.count {
                mutationLog("Hashed project inputs: \(index + 1)/\(orderedInputs.count) files.")
            }
        }
        content.append(configData)
        for argument in xcodebuildArguments {
            content.append(0)
            content.append(contentsOf: argument.utf8)
        }
        let environment = ProcessInfo.processInfo.environment
        let toolchainKeys = ["MUTEST_TOOLCHAIN_FINGERPRINT", "DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT", "SWIFT_VERSION", "ARCHS", "CONFIGURATION"]
        for key in toolchainKeys {
            content.append(0)
            content.append(contentsOf: key.utf8)
            content.append(0)
            content.append(contentsOf: (environment[key] ?? "").utf8)
        }
        content.append(contentsOf: "\u{0}0.3.0-xcode-workers-v3\u{0}\(runtimeFingerprint)\u{0}mutest-swift-cache-v3".utf8)
        return SHA256Digest.hash(content)
    }

    private func packageDependencyInputFiles(graph: PackageDependencyGraph, projectRoot: URL) -> [(String, URL)] {
        var result: [(String, URL)] = []
        let manager = FileManager.default
        for package in graph.localPackages where !isWithin(package, root: projectRoot) {
            guard let enumerator = manager.enumerator(at: package, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            for case let file as URL in enumerator {
                let relative = relativePath(file, root: package)
                if ProjectFilePaths.isGenerated(relative) {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let packagePath = PackageDependencyResolver.relativePath(package, to: graph.commonRoot)
                let stablePath = "@local-package/\(packagePath)/\(relative)"
                result.append((stablePath, file))
            }
        }
        return result
    }

    private func resolvedDependencyInputFiles(in sandbox: ProjectSandbox) -> [(String, URL)] {
        var result: [(String, URL)] = []
        var visited = Set<String>()
        let generated = Set([".git", ".build", ".swift-mutation-testing", "DerivedData"])
        for root in [sandbox.root] + sandbox.localPackages {
            guard visited.insert(root.path).inserted,
                  let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
            for case let file as URL in enumerator {
                let relative = relativePath(file, root: root)
                if relative.split(separator: "/").contains(where: { generated.contains(String($0)) }) {
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                    continue
                }
                guard file.lastPathComponent == "Package.resolved",
                      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let stagedPath = PackageDependencyResolver.relativePath(file, to: sandbox.container)
                result.append(("@resolved/\(stagedPath)", file))
            }
        }
        return result
    }

    private func makeSandbox(from source: URL, localPackageRoots: [URL], into parent: URL,
                             excluding excludedPaths: [URL]) throws -> ProjectSandbox {
        let source = source.standardizedFileURL
        let packages = Array(Set(localPackageRoots.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        let hasExternalPackages = packages.contains { !isWithin($0, root: source) }
        let referenceRoot = hasExternalPackages ? commonAncestor(of: [source] + packages) : source
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let container = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        do {
            let copyCandidates = [source] + packages
            let ordered = copyCandidates.sorted { $0.pathComponents.count < $1.pathComponents.count }
            var copyRoots: [URL] = []
            for candidate in ordered where !copyRoots.contains(where: { isWithin(candidate, root: $0) }) {
                copyRoots.append(candidate)
            }
            for copyRoot in copyRoots {
                let relative = PackageDependencyResolver.relativePath(copyRoot, to: referenceRoot)
                let destination = relative.isEmpty ? container : container.appendingPathComponent(relative, isDirectory: true)
                try copyTree(from: copyRoot, to: destination, excluding: excludedPaths)
            }
            let projectRelative = PackageDependencyResolver.relativePath(source, to: referenceRoot)
            let stagedRoot = projectRelative.isEmpty ? container : container.appendingPathComponent(projectRelative, isDirectory: true)
            let stagedPackages = packages.map { package in
                let relative = PackageDependencyResolver.relativePath(package, to: referenceRoot)
                return relative.isEmpty ? container : container.appendingPathComponent(relative, isDirectory: true)
            }
            return ProjectSandbox(container: container, root: stagedRoot, localPackages: stagedPackages)
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
    }

    private func copyTree(from source: URL, to destinationRoot: URL, excluding excludedPaths: [URL]) throws {
        let source = source.standardizedFileURL
        let sourcePath = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let excludedRelativePaths = excludedPaths.compactMap { path -> String? in
            let absolute = path.standardizedFileURL.path
            return absolute.hasPrefix(sourcePath) ? String(absolute.dropFirst(sourcePath.count)) : nil
        }
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for case let file as URL in enumerator {
            let relative = relativePath(file, root: source)
            let isRunArtifact = excludedRelativePaths.contains { relative == $0 || relative.hasPrefix($0 + "/") }
            if isRunArtifact || ProjectFilePaths.isGenerated(relative) {
                if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let destination = destinationRoot.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if values.isSymbolicLink == true { try FileManager.default.copyItem(at: file, to: destination) }
                else { try cloneFileOrCopy(from: file, to: destination) }
            }
        }
    }

    private func isWithin(_ path: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let candidate = path.standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private func commonAncestor(of urls: [URL]) -> URL {
        let paths = urls.map { $0.standardizedFileURL.pathComponents }
        guard var prefix = paths.first else { return URL(fileURLWithPath: "/", isDirectory: true) }
        for path in paths.dropFirst() {
            var count = 0
            while count < min(prefix.count, path.count), prefix[count] == path[count] { count += 1 }
            prefix = Array(prefix.prefix(count))
        }
        let path = prefix.first == "/" ? "/" + prefix.dropFirst().joined(separator: "/") : prefix.joined(separator: "/")
        return URL(fileURLWithPath: path.isEmpty ? "/" : path, isDirectory: true).standardizedFileURL
    }

    private func cloneFileOrCopy(from source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(sourcePath, destinationPath, nil, flags)
            }
        }
        if result == 0 { return }
        try? FileManager.default.removeItem(at: destination)
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
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
        TestExecutionCount.parse(output)
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
