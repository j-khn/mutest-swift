import Foundation
import MutationTestingSpec

private final class XcodeExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MutantRecord] = [:]
    private var warnings: [IntegrityWarning] = []
    private var retries: [MutationCandidate] = []
    private var errors: [any Error] = []
    private var baselineCounts: [Int] = []
    private var testRuns = 0
    private var isolatedBuildSeconds: TimeInterval = 0

    func baseline(_ count: Int) { lock.lock(); baselineCounts.append(count); lock.unlock() }
    func testRun() { lock.lock(); testRuns += 1; lock.unlock() }
    func isolatedBuild(_ seconds: TimeInterval) { lock.lock(); isolatedBuildSeconds += seconds; lock.unlock() }
    func error(_ error: any Error) { lock.lock(); errors.append(error); lock.unlock() }
    func retry(_ candidate: MutationCandidate, record: MutantRecord) { lock.lock(); retries.append(candidate); records[candidate.id] = record; lock.unlock() }
    func finish(_ record: MutantRecord, warnings: [IntegrityWarning]) { lock.lock(); records[record.id] = record; self.warnings += warnings; lock.unlock() }
    func takeRetries() -> [MutationCandidate] { lock.lock(); defer { lock.unlock() }; let result = retries; retries = []; return result }
    func snapshot() -> (records: [String: MutantRecord], warnings: [IntegrityWarning], errors: [any Error], baselineCounts: [Int], testRuns: Int, isolatedBuildSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (records, warnings, errors, baselineCounts, testRuns, isolatedBuildSeconds)
    }
}

struct XcodeMutationExecutionResult {
    var records: [String: MutantRecord]
    var warnings: [IntegrityWarning]
    var timings: MutationTimings
    var baselineCounts: [Int]
    var mutantTestRunCount: Int
    var workerCount: Int
    var simulatorSetupSeconds: TimeInterval
}

/// Xcode orchestration deliberately lives outside the language-neutral contract and SwiftPM
/// scheduler. Only a checked-out sandbox is edited; every worker owns its mutable artifacts.
final class XcodeMutationExecutor: @unchecked Sendable {
    private let configuration: RunConfiguration
    private let adapter: NativeTestAdapter
    private let selection: ResolvedTestSelection
    private let sandbox: URL
    private let output: URL
    private let sources: [String: String]
    private let createSandbox: @Sendable () throws -> URL
    private let onVerdict: @Sendable (MutantRecord, [IntegrityWarning]) throws -> Void
    private let onCompletion: @Sendable (MutationCandidate, MutantStatus) -> Void
    private let state = XcodeExecutionState()
    private let commandRunner: XcodeCommandRunner
    private let cleanupRunner: XcodeCommandRunner
    private let workerRegistryDirectory: URL?

    init(configuration: RunConfiguration, adapter: NativeTestAdapter, selection: ResolvedTestSelection,
         sandbox: URL, output: URL, sources: [String: String],
         createSandbox: @escaping @Sendable () throws -> URL,
         onVerdict: @escaping @Sendable (MutantRecord, [IntegrityWarning]) throws -> Void,
         onCompletion: @escaping @Sendable (MutationCandidate, MutantStatus) -> Void,
         commandRunner: @escaping XcodeCommandRunner = { try ProcessRunner().run($0) },
         cleanupRunner: @escaping XcodeCommandRunner = { try ProcessRunner(ignoresCancellation: true).run($0) },
         workerRegistryDirectory: URL? = nil) {
        self.configuration = configuration; self.adapter = adapter; self.selection = selection
        self.sandbox = sandbox; self.output = output; self.sources = sources
        self.createSandbox = createSandbox; self.onVerdict = onVerdict; self.onCompletion = onCompletion
        self.commandRunner = commandRunner; self.cleanupRunner = cleanupRunner
        self.workerRegistryDirectory = workerRegistryDirectory
    }

    func run(template: XcodeSimulatorTemplate, candidates: [MutationCandidate], historicalDurations: [String: TimeInterval]) throws -> XcodeMutationExecutionResult {
        let workerCount = min(configuration.parallelism, max(1, candidates.count))
        mutationLog("Xcode workers: requested \(configuration.parallelism), active \(workerCount). Each mutant uses the complete selected test scope.")
        let pool = try XcodeSimulatorPool(template: template, count: workerCount, output: output,
            registryDirectory: workerRegistryDirectory ?? XcodeSimulatorPool.persistentRegistryDirectory(), run: commandRunner, teardownRun: cleanupRunner)
        var cleaned = false
        defer { for worker in pool.workers { if let root = worker.isolatedRoot { try? FileManager.default.removeItem(at: root) } } }
        defer { if !cleaned { for warning in pool.cleanup() { mutationLog(warning.message) } } }
        var timings = MutationTimings()
        let builderData = sandbox.appendingPathComponent(".swift-mutation-testing/DerivedData")
        let generator = SwiftMutationGenerator()
        var schemaCandidates: [MutationCandidate] = []
        var isolatedCandidates: [MutationCandidate] = []
        for (path, source) in sources {
            let schema = generator.makeSchema(source: source, candidates: candidates.filter { $0.source == path })
            schemaCandidates += candidates.filter { $0.source == path && schema.included.contains($0.id) }
            isolatedCandidates += schema.isolated
            try schema.source.write(to: sandbox.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let initialBuild = try build(root: sandbox, derivedData: builderData, worker: pool.workers[0], label: "schema-build")
        timings.schemaBuildSeconds += initialBuild.elapsed
        let schemaFailed = initialBuild.timedOut || initialBuild.exitCode != 0
        if schemaFailed {
            try restoreSources(in: sandbox)
            let original = try build(root: sandbox, derivedData: builderData, worker: pool.workers[0], label: "baseline-build")
            timings.schemaBuildSeconds += original.elapsed
            guard !original.timedOut, original.exitCode == 0 else { throw MutationEngineError.baselineFailed(log: original.outputFile, timedOut: original.timedOut) }
        }
        let simulatorSetupSeconds = try pool.waitUntilReady()
        timings.baselineSeconds += try prepareAndValidateWorkers(pool: pool, derivedData: builderData)
        let mutationStartedAt = Date()
        let ordered = candidates.sorted {
            let left = historicalDurations[$0.id] ?? 0, right = historicalDurations[$1.id] ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        func sorted(_ batch: [MutationCandidate]) -> [MutationCandidate] { batch.sorted { order[$0.id, default: 0] < order[$1.id, default: 0] } }
        if !schemaFailed {
            try executeBatch(sorted(schemaCandidates), pool: pool, isolated: false)
        } else {
            // Rebuild smaller groups, draining workers before replacing their frozen snapshots.
            func narrowed(_ batch: [MutationCandidate]) throws {
                guard !batch.isEmpty else { return }
                for (path, source) in sources {
                    let schema = generator.makeSchema(source: source, candidates: batch.filter { $0.source == path })
                    try schema.source.write(to: sandbox.appendingPathComponent(path), atomically: true, encoding: .utf8)
                }
                let result = try build(root: sandbox, derivedData: builderData, worker: pool.workers[0], label: "schema-narrowed-\(UUID().uuidString)")
                timings.schemaBuildSeconds += result.elapsed
                if result.timedOut || result.exitCode != 0 {
                    if batch.count == 1 { isolatedCandidates.append(batch[0]); return }
                    let middle = batch.count / 2
                    try narrowed(Array(batch[..<middle])); try narrowed(Array(batch[middle...])); return
                }
                timings.baselineSeconds += try prepareAndValidateWorkers(pool: pool, derivedData: builderData)
                try executeBatch(sorted(batch), pool: pool, isolated: false)
            }
            try narrowed(sorted(schemaCandidates))
        }
        if !isolatedCandidates.isEmpty {
            try restoreSources(in: sandbox)
            for worker in pool.workers {
                let root = try createSandbox()
                worker.isolatedRoot = root
                try restoreSources(in: root)
            }
            try executeBatch(sorted(isolatedCandidates), pool: pool, isolated: true)
        }
        timings.mutantRunSeconds = Date().timeIntervalSince(mutationStartedAt)
        let completed = state.snapshot()
        timings.isolatedBuildSeconds = completed.isolatedBuildSeconds
        let cleanupStarted = Date()
        let cleanupWarnings = pool.cleanup()
        cleaned = true
        timings.cleanupSeconds = Date().timeIntervalSince(cleanupStarted)
        return .init(records: completed.records, warnings: completed.warnings + cleanupWarnings, timings: timings,
                     baselineCounts: completed.baselineCounts, mutantTestRunCount: completed.testRuns,
                     workerCount: workerCount, simulatorSetupSeconds: simulatorSetupSeconds)
    }

    private func build(root: URL, derivedData: URL, worker: XcodeSimulatorWorker, label: String) throws -> CommandResult {
        mutationLog("Building Xcode test products: \(label)")
        return try commandRunner(adapter.command(root: root, phase: .buildForTesting, resolved: selection, environment: [:],
            timeout: TimeInterval(configuration.timeouts.buildSeconds), output: log(label),
            xcodeContext: .init(destination: worker.destination, derivedDataPath: derivedData)))
    }

    private func snapshot(worker: XcodeSimulatorWorker, derivedData: URL) throws {
        if let old = worker.artifacts { try FileManager.default.removeItem(at: old.products.deletingLastPathComponent()) }
        worker.artifacts = nil
        worker.artifacts = try XcodeTestArtifacts.snapshot(derivedData: derivedData,
            into: worker.directory.appendingPathComponent("artifacts-\(UUID().uuidString)"), testTarget: configuration.project.testTarget!)
    }

    private func prepareAndValidateWorkers(pool: XcodeSimulatorPool, derivedData: URL) throws -> TimeInterval {
        let started = Date()
        for worker in pool.workers { try snapshot(worker: worker, derivedData: derivedData) }
        let before = state.snapshot().baselineCounts.count
        for worker in pool.workers {
            if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
            let label = "baseline-worker-\(worker.number)-\(UUID().uuidString)"
            let result = try runTests(worker: worker, mutantID: nil,
                timeout: TimeInterval(configuration.timeouts.baselineSeconds), label: label)
            guard !result.timedOut, result.exitCode == 0 else {
                throw MutationEngineError.baselineFailed(log: result.outputFile, timedOut: result.timedOut)
            }
            guard let count = TestExecutionCount.parse(result.output), count > 0 else {
                throw MutationEngineError.baselineRanNoTests(log: result.outputFile)
            }
            state.baseline(count)
            mutationLog("Worker \(worker.number) baseline passed: \(count) tests.")
        }
        try checkErrors()
        let counts = state.snapshot().baselineCounts
        guard counts.count == before + pool.workers.count, Set(counts).count == 1 else {
            throw MutationEngineError.invalidProject("Xcode workers ran different baseline test counts: \(counts). No mutation score was produced.")
        }
        return Date().timeIntervalSince(started)
    }

    private func executeBatch(_ candidates: [MutationCandidate], pool: XcodeSimulatorPool, isolated: Bool) throws {
        guard !candidates.isEmpty else { return }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = pool.workers.count
        for candidate in candidates {
            queue.addOperation { [self] in
                let worker = pool.acquire()
                defer { pool.release(worker) }
                do {
                    if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
                    let outcome = try execute(candidate, worker: worker, pool: pool, isolated: isolated, retry: false)
                    if outcome.record.status == .timeout && pool.workers.count > 1 && configuration.timeouts.parallelRetry {
                        state.retry(candidate, record: outcome.record)
                    } else { try finish(candidate, record: outcome.record, warnings: outcome.warnings) }
                } catch { state.error(error) }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        try checkErrors()
        for candidate in state.takeRetries() {
            let worker = pool.acquire()
            defer { pool.release(worker) }
            mutationLog("Retrying timed-out mutant \(candidate.id) alone with \(configuration.timeouts.retryMultiplier)x timeout.")
            try pool.reset(worker)
            var outcome = try execute(candidate, worker: worker, pool: pool, isolated: isolated, retry: true)
            outcome.record.durationSeconds = (outcome.record.durationSeconds ?? 0) + (state.snapshot().records[candidate.id]?.durationSeconds ?? 0)
            outcome.record.message = "Timed out in parallel; retried in isolation with \(configuration.timeouts.retryMultiplier)x timeout. " + (outcome.record.message ?? "")
            try finish(candidate, record: outcome.record, warnings: outcome.warnings)
        }
    }

    private func execute(_ candidate: MutationCandidate, worker: XcodeSimulatorWorker, pool: XcodeSimulatorPool, isolated: Bool, retry: Bool) throws -> (record: MutantRecord, warnings: [IntegrityWarning]) {
        var buildSeconds: TimeInterval = 0
        if isolated {
            guard let root = worker.isolatedRoot, let source = sources[candidate.source] else { throw MutationEngineError.invalidProject("Missing isolated worker source.") }
            let file = root.appendingPathComponent(candidate.source)
            defer { try? source.write(to: file, atomically: true, encoding: .utf8) }
            try SwiftMutationGenerator().makeIsolatedSchema(source: source, candidate: candidate).write(to: file, atomically: true, encoding: .utf8)
            let derivedData = root.appendingPathComponent(".swift-mutation-testing/DerivedData")
            let build = try self.build(root: root, derivedData: derivedData, worker: worker, label: "isolated-build-\(candidate.id)-\(retry)")
            buildSeconds = build.elapsed
            state.isolatedBuild(buildSeconds)
            if build.timedOut || build.exitCode != 0 {
                var record = candidate.record
                record.status = .unbuildable; record.durationSeconds = buildSeconds
                record.message = "Isolated mutant build \(build.timedOut ? "timed out" : "failed"); see \(build.outputFile.path)."
                return (record, [])
            }
            try snapshot(worker: worker, derivedData: derivedData)
        }
        let timeout = TimeInterval(configuration.timeouts.mutantSeconds) * (retry ? configuration.timeouts.retryMultiplier : 1)
        let result = try runTests(worker: worker, mutantID: candidate.id, timeout: timeout,
                                 label: "\(retry ? "retry-isolated" : "mutant")-\(candidate.id)")
        let activated = result.output.contains("SWIFT_MUTATION_ACTIVATED:\(candidate.id)")
        var record = candidate.record
        record.durationSeconds = buildSeconds + result.elapsed; record.activated = activated
        if result.timedOut { record.status = .timeout }
        else if !activated { record.status = .noCoverage }
        else { record.status = result.exitCode == 0 ? .survived : .killed }
        if result.stoppedEarly { record.message = "Stopped after a selected test failed while this mutant was active." }
        var warnings: [IntegrityWarning] = []
        if TestExecutionCount.parse(result.output) == 0 && !result.stoppedEarly && !activated {
            warnings.append(.init(code: "testsNotExecuted", message: "The selected test command reported zero tests.", mutantId: candidate.id))
        } else if !activated && result.exitCode != 0 && !result.timedOut {
            warnings.append(.init(code: "testsFailedWithoutActivation", message: "Xcode test execution failed without activating the mutant; verdict is noCoverage.", mutantId: candidate.id))
        }
        if result.stoppedEarly || result.timedOut || result.exitCode != 0 {
            try pool.sanitize(worker, hostBundleIDs: worker.artifacts?.hostBundleIDs ?? [])
        }
        return (record, warnings)
    }

    private func runTests(worker: XcodeSimulatorWorker, mutantID: String?, timeout: TimeInterval, label: String) throws -> CommandResult {
        guard let artifacts = worker.artifacts else { throw MutationEngineError.invalidProject("Worker has no test products.") }
        let environment = mutantID.map { ["SWIFT_MUTATION_ID": $0] } ?? [:]
        let manifest = try artifacts.invocationManifest(environment: environment)
        defer { try? FileManager.default.removeItem(at: manifest) }
        let bundle = output.appendingPathComponent("results/\(label)-\(UUID().uuidString).xcresult")
        let command = try adapter.command(root: worker.isolatedRoot ?? sandbox, phase: .testWithoutBuilding,
            resolved: selection, environment: [:], timeout: timeout, output: log(label),
            stopOnActivatedTestFailure: mutantID != nil, activationID: mutantID,
            xcodeContext: .init(destination: worker.destination, derivedDataPath: worker.directory.appendingPathComponent("DerivedData"), testRunFile: manifest, resultBundlePath: bundle))
        if mutantID != nil { state.testRun() }
        return try commandRunner(command)
    }

    private func finish(_ candidate: MutationCandidate, record: MutantRecord, warnings: [IntegrityWarning]) throws {
        try onVerdict(record, warnings)
        state.finish(record, warnings: warnings)
        onCompletion(candidate, record.status)
    }

    private func checkErrors() throws {
        if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
        if let error = state.snapshot().errors.first { throw error }
    }
    private func restoreSources(in root: URL) throws {
        for (path, source) in sources { try source.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    }
    private func log(_ label: String) -> URL { output.appendingPathComponent("logs/\(label).log") }
}
