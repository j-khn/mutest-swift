import Foundation

private final class XcodeExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: MutantRecord] = [:]
    private var warnings: [IntegrityWarning] = []
    private var retries: [MutationCandidate] = []
    private var errors: [any Error] = []
    private var baselineCounts: [Int] = []
    private var testRuns = 0
    private var mutantTestCaseExecutionCount = 0
    private var mutantTestRunCountWithoutReportedCaseCount = 0
    private var mutantTestRuns: [MutantTestRunDetails] = []
    private var isolatedBuildSeconds: TimeInterval = 0
    private var resultBundles: [URL] = []

    func resultBundle(_ url: URL) { lock.lock(); resultBundles.append(url); lock.unlock() }
    func removeResultBundles() {
        lock.lock(); let bundles = resultBundles; lock.unlock()
        for bundle in bundles { try? FileManager.default.removeItem(at: bundle) }
    }

    func baseline(_ count: Int) { lock.lock(); baselineCounts.append(count); lock.unlock() }
    func testRun(_ details: MutantTestRunDetails) {
        lock.lock()
        testRuns += 1
        mutantTestRuns.append(details)
        if let reportedCaseCount = details.reportedCaseCount { mutantTestCaseExecutionCount += reportedCaseCount }
        else { mutantTestRunCountWithoutReportedCaseCount += 1 }
        lock.unlock()
    }
    func isolatedBuild(_ seconds: TimeInterval) { lock.lock(); isolatedBuildSeconds += seconds; lock.unlock() }
    func error(_ error: any Error) { lock.lock(); errors.append(error); lock.unlock() }
    func retry(_ candidate: MutationCandidate, record: MutantRecord) { lock.lock(); retries.append(candidate); records[candidate.id] = record; lock.unlock() }
    func finish(_ record: MutantRecord, warnings: [IntegrityWarning]) { lock.lock(); records[record.id] = record; self.warnings += warnings; lock.unlock() }
    func takeRetries() -> [MutationCandidate] { lock.lock(); defer { lock.unlock() }; let result = retries; retries = []; return result }
    func snapshot() -> (records: [String: MutantRecord], warnings: [IntegrityWarning], errors: [any Error], baselineCounts: [Int], testRuns: Int, mutantTestCaseExecutionCount: Int, mutantTestRunCountWithoutReportedCaseCount: Int, mutantTestRuns: [MutantTestRunDetails], isolatedBuildSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (records, warnings, errors, baselineCounts, testRuns, mutantTestCaseExecutionCount, mutantTestRunCountWithoutReportedCaseCount, mutantTestRuns, isolatedBuildSeconds)
    }
}

struct XcodeMutationExecutionResult {
    var records: [String: MutantRecord]
    var warnings: [IntegrityWarning]
    var timings: MutationTimings
    var baselineCounts: [Int]
    var mutantTestRunCount: Int
    var mutantTestCaseExecutionCount: Int
    var mutantTestRunCountWithoutReportedCaseCount: Int
    var mutantTestRuns: [MutantTestRunDetails]
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
    private let createSandbox: @Sendable () throws -> ProjectSandbox
    private let onVerdict: @Sendable (MutantRecord, [IntegrityWarning]) throws -> Void
    private let onCompletion: @Sendable (MutationCandidate, MutantStatus) -> Void
    private let state = XcodeExecutionState()
    private let commandRunner: XcodeCommandRunner
    private let cleanupRunner: XcodeCommandRunner
    private let workerRegistryDirectory: URL?
    private let buildWorkspace: XcodeBuildWorkspace?
    private let buildLock = NSLock()

    init(configuration: RunConfiguration, adapter: NativeTestAdapter, selection: ResolvedTestSelection,
         sandbox: URL, output: URL, sources: [String: String], buildWorkspace: XcodeBuildWorkspace? = nil,
         createSandbox: @escaping @Sendable () throws -> ProjectSandbox,
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
        self.buildWorkspace = buildWorkspace
    }

    func run(template: XcodeSimulatorTemplate, candidates: [MutationCandidate], historicalDurations: [String: TimeInterval]) throws -> XcodeMutationExecutionResult {
        let workerCount = min(configuration.parallelism, max(1, candidates.count))
        mutationLog("Xcode workers: requested \(configuration.parallelism), active \(workerCount). Each mutant uses the complete selected test scope.")
        let workspace = try buildWorkspace ?? XcodeBuildWorkspace()
        defer { if buildWorkspace == nil { workspace.cleanup() } }
        let pool = try XcodeSimulatorPool(template: template, count: workerCount, output: output,
            registryDirectory: workerRegistryDirectory ?? XcodeSimulatorPool.persistentRegistryDirectory(), deferBoot: true, run: commandRunner, teardownRun: cleanupRunner)
        var cleaned = false
        // Xcode may finish writing result attachments after an attempt returns.
        // Sweep this campaign's bundles again after worker teardown to catch late files.
        defer { state.removeResultBundles() }
        defer {
            for worker in pool.workers {
                if let container = worker.isolatedContainer { try? FileManager.default.removeItem(at: container) }
                else if let root = worker.isolatedRoot { try? FileManager.default.removeItem(at: root) }
            }
        }
        defer { if !cleaned { for warning in pool.cleanup() { mutationLog(warning.message) } } }
        var timings = MutationTimings()
        let builderData = workspace.derivedData
        mutationLog("Building test products before simulator startup; Xcode builds use at most 2 jobs. Build files are outside the source tree.")
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
            // A failed schematized build can leave an incomplete .xctestrun manifest.
            // Force the successful original-source build to write a fresh manifest.
            try XcodeTestArtifacts.removeGeneratedManifests(derivedData: builderData)
            let original = try build(root: sandbox, derivedData: builderData, worker: pool.workers[0], label: "baseline-build")
            timings.schemaBuildSeconds += original.elapsed
            guard !original.timedOut, original.exitCode == 0 else { throw MutationEngineError.baselineBuildFailed(log: original.outputFile, timedOut: original.timedOut) }
        }
        mutationLog("Test products built. Starting simulator workers one at a time…")
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
            func narrowed(_ batch: [MutationCandidate], afterFailure failure: SchemaBuildFailure? = nil) throws {
                guard !batch.isEmpty else { return }
                if let failure {
                    let implicated = SchemaBuildFailureAttribution.implicatedCandidates(
                        in: failure.output,
                        candidates: batch,
                        sources: sources
                    )
                    if batch.count == 1 {
                        let candidate = batch[0]
                        if !failure.timedOut, implicated.contains(where: { $0.id == candidate.id }) {
                            var record = candidate.record
                            record.status = .unbuildable
                            record.message = "Mutant did not compile when built alone in the schema; see \(failure.log.path)."
                            try finish(candidate, record: record, warnings: [])
                        } else {
                            isolatedCandidates.append(candidate)
                        }
                        return
                    }
                    if !implicated.isEmpty {
                        let implicatedIDs = Set(implicated.map(\.id))
                        isolatedCandidates += implicated
                        try narrowed(batch.filter { !implicatedIDs.contains($0.id) })
                        return
                    }
                    let middle = batch.count / 2
                    try narrowed(Array(batch[..<middle]))
                    try narrowed(Array(batch[middle...]))
                    return
                }
                for (path, source) in sources {
                    let schema = generator.makeSchema(source: source, candidates: batch.filter { $0.source == path })
                    try schema.source.write(to: sandbox.appendingPathComponent(path), atomically: true, encoding: .utf8)
                }
                let result = try build(root: sandbox, derivedData: builderData, worker: pool.workers[0], label: "schema-narrowed-\(UUID().uuidString)")
                timings.schemaBuildSeconds += result.elapsed
                if result.timedOut || result.exitCode != 0 {
                    try narrowed(batch, afterFailure: .init(output: result.output, log: result.outputFile, timedOut: result.timedOut))
                    return
                }
                let snapshotsStarted = Date()
                try snapshotWorkers(pool: pool, derivedData: builderData)
                timings.sandboxCopySeconds += Date().timeIntervalSince(snapshotsStarted)
                try executeBatch(sorted(batch), pool: pool, isolated: false)
            }
            try narrowed(sorted(schemaCandidates), afterFailure: .init(output: initialBuild.output, log: initialBuild.outputFile, timedOut: initialBuild.timedOut))
        }
        if !isolatedCandidates.isEmpty {
            try restoreSources(in: sandbox)
            for worker in pool.workers {
                let copy = try createSandbox()
                worker.isolatedRoot = copy.root
                worker.isolatedContainer = copy.container
                try restoreSources(in: copy.root)
            }
            try executeBatch(sorted(isolatedCandidates), pool: pool, isolated: true, buildWorkspace: workspace)
        }
        timings.mutantRunSeconds = Date().timeIntervalSince(mutationStartedAt)
        let completed = state.snapshot()
        timings.isolatedBuildSeconds = completed.isolatedBuildSeconds
        let cleanupStarted = Date()
        let cleanupWarnings = pool.cleanup()
        cleaned = true
        timings.cleanupSeconds = Date().timeIntervalSince(cleanupStarted)
        let baselineTestExecutionCount = completed.baselineCounts.reduce(0, +)
        let baselineTestCount = completed.baselineCounts.first.map(String.init) ?? "unavailable"
        mutationLog("Test counts: \(baselineTestCount) baseline tests per worker (\(baselineTestExecutionCount) baseline executions); \(completed.mutantTestCaseExecutionCount) mutant test cases reported across \(completed.testRuns) mutant test runs; \(completed.mutantTestRunCountWithoutReportedCaseCount) mutant runs did not report a case count.")
        return .init(records: completed.records, warnings: completed.warnings + cleanupWarnings, timings: timings,
                     baselineCounts: completed.baselineCounts, mutantTestRunCount: completed.testRuns,
                     mutantTestCaseExecutionCount: completed.mutantTestCaseExecutionCount,
                     mutantTestRunCountWithoutReportedCaseCount: completed.mutantTestRunCountWithoutReportedCaseCount,
                     mutantTestRuns: completed.mutantTestRuns,
                     workerCount: workerCount, simulatorSetupSeconds: simulatorSetupSeconds)
    }

    private func build(root: URL, derivedData: URL, worker: XcodeSimulatorWorker, label: String) throws -> CommandResult {
        // Independent worker build folders prevent build-lock conflicts. Serialize
        // expensive builds so multiple cold plugin/compiler graphs cannot compete.
        buildLock.lock(); defer { buildLock.unlock() }
        if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
        mutationLog("Building Xcode test products: \(label)")
        return try commandRunner(adapter.command(root: root, phase: .buildForTesting, resolved: selection, environment: [:],
            timeout: TimeInterval(configuration.timeouts.buildSeconds), output: log(label),
            xcodeContext: .init(destination: worker.destination, derivedDataPath: derivedData)))
    }

    private func snapshot(worker: XcodeSimulatorWorker, derivedData: URL) throws {
        if let old = worker.artifacts { try FileManager.default.removeItem(at: old.products.deletingLastPathComponent()) }
        worker.artifacts = nil
        worker.artifacts = try XcodeTestArtifacts.snapshot(derivedData: derivedData,
            into: worker.directory.appendingPathComponent("artifacts-\(UUID().uuidString)"), testTargets: selection.targets)
    }

    private func prepareAndValidateWorkers(pool: XcodeSimulatorPool, derivedData: URL) throws -> TimeInterval {
        let started = Date()
        try snapshotWorkers(pool: pool, derivedData: derivedData)
        let before = state.snapshot().baselineCounts.count
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = pool.workers.count
        for worker in pool.workers {
            queue.addOperation { [self] in
                do {
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
                } catch {
                    state.error(error)
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        try checkErrors()
        let counts = state.snapshot().baselineCounts
        guard counts.count == before + pool.workers.count, Set(counts).count == 1 else {
            throw MutationEngineError.invalidProject("Xcode workers ran different baseline test counts: \(counts). No mutation score was produced.")
        }
        return Date().timeIntervalSince(started)
    }

    private func snapshotWorkers(pool: XcodeSimulatorPool, derivedData: URL) throws {
        for worker in pool.workers { try snapshot(worker: worker, derivedData: derivedData) }
    }

    private func executeBatch(_ candidates: [MutationCandidate], pool: XcodeSimulatorPool, isolated: Bool, buildWorkspace: XcodeBuildWorkspace? = nil) throws {
        guard !candidates.isEmpty else { return }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = pool.workers.count
        for candidate in candidates {
            queue.addOperation { [self] in
                let worker = pool.acquire()
                defer { pool.release(worker) }
                do {
                    if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
                    let outcome = try execute(candidate, worker: worker, pool: pool, isolated: isolated, retry: false, buildWorkspace: buildWorkspace)
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
            var outcome = try execute(candidate, worker: worker, pool: pool, isolated: isolated, retry: true, buildWorkspace: buildWorkspace)
            outcome.record.durationSeconds = (outcome.record.durationSeconds ?? 0) + (state.snapshot().records[candidate.id]?.durationSeconds ?? 0)
            outcome.record.message = "Timed out in parallel; retried in isolation with \(configuration.timeouts.retryMultiplier)x timeout. " + (outcome.record.message ?? "")
            try finish(candidate, record: outcome.record, warnings: outcome.warnings)
        }
    }

    private func execute(_ candidate: MutationCandidate, worker: XcodeSimulatorWorker, pool: XcodeSimulatorPool, isolated: Bool, retry: Bool, buildWorkspace: XcodeBuildWorkspace?) throws -> (record: MutantRecord, warnings: [IntegrityWarning]) {
        var buildSeconds: TimeInterval = 0
        if isolated {
            guard let root = worker.isolatedRoot, let source = sources[candidate.source] else { throw MutationEngineError.invalidProject("Missing isolated worker source.") }
            let file = root.appendingPathComponent(candidate.source)
            defer { try? source.write(to: file, atomically: true, encoding: .utf8) }
            try SwiftMutationGenerator().makeIsolatedSchema(source: source, candidate: candidate).write(to: file, atomically: true, encoding: .utf8)
            guard let buildWorkspace else { throw MutationEngineError.invalidProject("Missing isolated Xcode build workspace.") }
            let derivedData = buildWorkspace.isolatedDerivedData(worker: worker.number)
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
        let result = try runTests(worker: worker, mutantID: candidate.id, source: candidate.source, timeout: timeout,
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

    private func runTests(worker: XcodeSimulatorWorker, mutantID: String?, source: String? = nil, timeout: TimeInterval, label: String) throws -> CommandResult {
        guard let artifacts = worker.artifacts else { throw MutationEngineError.invalidProject("Worker has no test products.") }
        let environment = mutantID.map { ["SWIFT_MUTATION_ID": $0] } ?? [:]
        let manifest = try artifacts.invocationManifest(environment: environment)
        defer { try? FileManager.default.removeItem(at: manifest) }
        // Baseline counts come from the test output, so only mutant runs need an xcresult
        // bundle for the per-file test-name report. Remove each bundle as soon as it is read.
        let bundle = mutantID.map { _ in output.appendingPathComponent("results/\(label)-\(UUID().uuidString).xcresult") }
        if let bundle { state.resultBundle(bundle) }
        defer { if let bundle { try? FileManager.default.removeItem(at: bundle) } }
        let command = try adapter.command(root: worker.isolatedRoot ?? sandbox, phase: .testWithoutBuilding,
            resolved: selection, environment: [:], timeout: timeout, output: log(label),
            stopOnActivatedTestFailure: mutantID != nil, activationID: mutantID,
            xcodeContext: .init(destination: worker.destination, derivedDataPath: worker.directory.appendingPathComponent("DerivedData"), testRunFile: manifest, resultBundlePath: bundle))
        let result = try commandRunner(command)
        if let mutantID, let bundle {
            let testCases = try XcodeTestResultReader.readCases(from: bundle, relativeTo: worker.isolatedRoot ?? sandbox)
            state.testRun(.init(mutantId: mutantID, source: source ?? "<unknown>",
                                reportedCaseCount: TestExecutionCount.parse(result.output), testCases: testCases))
        }
        return result
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
        for (path, source) in sources {
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.write(to: destination, atomically: true, encoding: .utf8)
        }
    }
    private func log(_ label: String) -> URL { output.appendingPathComponent("logs/\(label).log") }
}
