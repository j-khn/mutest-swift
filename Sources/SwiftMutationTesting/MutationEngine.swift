import Foundation
import MutationTestingSpec
#if canImport(Darwin)
import Darwin
#endif

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
        var timings = MutationTimings()
        let sandboxCopyStarted = Date()
        let sandbox = try makeSandbox(
            from: root,
            into: output.appendingPathComponent("sandboxes", isDirectory: true),
            excluding: [output] + (cacheDirectory.map { [$0] } ?? [])
        )
        timings.sandboxCopySeconds = Date().timeIntervalSince(sandboxCopyStarted)
        var auxiliarySandboxes: [URL] = []
        var sandboxRemoved = false
        defer {
            if !sandboxRemoved {
                auxiliarySandboxes.forEach { try? FileManager.default.removeItem(at: $0) }
                try? FileManager.default.removeItem(at: sandbox)
            }
        }
        let testDiscoveryStarted = Date()
        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: configuration.tests,
            testTarget: configuration.project.testTarget,
            forXcode: configuration.project.kind != .swiftPackage
        )
        timings.testDiscoverySeconds = Date().timeIntervalSince(testDiscoveryStarted)
        let adapter = NativeTestAdapter(project: adapterProject, selection: configuration.tests, xcodebuildArguments: xcodebuildArguments)
        let runner = ProcessRunner()
        let baselineLog = logs.appendingPathComponent("baseline.log")
        var baselineValidated = false
        var mutationPhaseStarted: Date?
        func validateBaseline(phase: TestPhase) throws {
            let baselineStarted = Date()
            let baseline = try runner.run(adapter.command(root: sandbox, phase: phase, resolved: selection, environment: [:], timeout: TimeInterval(configuration.timeouts.baselineSeconds), output: baselineLog))
            timings.baselineSeconds += Date().timeIntervalSince(baselineStarted)
            guard !baseline.timedOut && baseline.exitCode == 0 else { throw MutationEngineError.baselineFailed(log: baselineLog, timedOut: baseline.timedOut) }
            guard let baselineTestCount = executedTestCount(in: baseline.output), baselineTestCount > 0 else {
                throw MutationEngineError.baselineRanNoTests(log: baselineLog)
            }
            baselineValidated = true
            mutationPhaseStarted = Date()
        }

        let sourceDiscoveryStarted = Date()
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
        timings.sourceDiscoverySeconds = Date().timeIntervalSince(sourceDiscoveryStarted)

        var digestConfiguration = configuration
        digestConfiguration.project.path = configuration.project.kind == .swiftPackage ? "." : adapterProject.path
        digestConfiguration.cache = .init(enabled: true)
        digestConfiguration.resume = true
        digestConfiguration.qualityGate = .init()
        digestConfiguration.output = .init()
        let journalDirectory = cacheDirectory ?? output
        let inputHashStarted = Date()
        let inputDigest = try digestInputs(root: root, files: sourceFiles, configuration: digestConfiguration, xcodebuildArguments: xcodebuildArguments, excluding: [output, journalDirectory])
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

        if !remaining.isEmpty {
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
                            try clean.write(to: worker.appendingPathComponent(relative), atomically: true, encoding: .utf8)
                        }
                        workerRoots.append(worker)
                        auxiliarySandboxes.append(worker)
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
        auxiliarySandboxes.forEach { try? FileManager.default.removeItem(at: $0) }
        try? FileManager.default.removeItem(at: sandbox)
        sandboxRemoved = true
        timings.cleanupSeconds = Date().timeIntervalSince(cleanupStarted)
        let report = MutationReport(scope: .init(sources: selectedSources, tests: selection.identifiers, allTests: selection.allTests), mutants: orderedRecords, integrityWarnings: warnings, qualityGate: gate, timings: timings)
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

    private func digestInputs(root: URL, files: [URL], configuration: RunConfiguration, xcodebuildArguments: [String], excluding excludedPaths: [URL]) throws -> String {
        var inputs: [String: URL] = [:]
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
                inputs[relative] = file
            }
        }
        // Explicit source selections may include paths outside conventional project enumeration
        // layouts. Add them even if the enumerator filtered or skipped an unusual file type.
        for file in files { inputs[relativePath(file, root: root)] = file }
        let configurationEncoder = JSONEncoder()
        configurationEncoder.outputFormatting = [.sortedKeys]
        let configData = try configurationEncoder.encode(configuration)
        var content = Data()
        for (path, file) in inputs.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            let fileDigest = SHA256Digest.hash(data)
            content.append(contentsOf: path.utf8)
            content.append(0)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { content.append(contentsOf: $0) }
            content.append(contentsOf: fileDigest.utf8)
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
        content.append(contentsOf: "\u{0}0.2.0\u{0}swift-mutation-testing-spec-1.0.0".utf8)
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
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
            else {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if values.isSymbolicLink == true { try FileManager.default.copyItem(at: file, to: destination) }
                else { try cloneFileOrCopy(from: file, to: destination) }
            }
        }
        return sandbox
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
