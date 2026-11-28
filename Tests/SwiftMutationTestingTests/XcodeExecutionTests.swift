import Foundation
import Testing
@testable import SwiftMutationTesting

private final class FakeXcode: @unchecked Sendable {
    let simulators = FakeSimulators()
    private let lock = NSLock()
    private var active = 0
    private var activeBaselines = 0
    private(set) var maximumActive = 0
    private(set) var maximumActiveBaselines = 0
    private(set) var attempts: [(String, String, TimeInterval)] = []
    private(set) var builds: [CommandSpec] = []
    private(set) var buildSources: [String] = []
    private(set) var initialBuildSawBoot = false
    private(set) var maximumActiveBuilds = 0
    private var activeBuilds = 0
    private var didFailRuleTimeoutBuild = false
    let failSchema: Bool
    let failOriginalBuild: Bool
    let failFirstBuildWithRuleTimeout: Bool
    let timeoutFirstAttempt: Bool
    let mismatchBaseline: Bool
    let failInitialSchemaOnly: Bool
    let failInactiveSchemaBaseline: Bool
    let failOriginalRecheck: Bool
    let failWithoutActivation: Bool
    init(failSchema: Bool = false, failOriginalBuild: Bool = false, timeoutFirstAttempt: Bool = false,
         mismatchBaseline: Bool = false, failInitialSchemaOnly: Bool = false,
         failInactiveSchemaBaseline: Bool = false, failOriginalRecheck: Bool = false,
         failWithoutActivation: Bool = false, failFirstBuildWithRuleTimeout: Bool = false) {
        self.failSchema = failSchema; self.timeoutFirstAttempt = timeoutFirstAttempt; self.mismatchBaseline = mismatchBaseline
        self.failOriginalBuild = failOriginalBuild
        self.failFirstBuildWithRuleTimeout = failFirstBuildWithRuleTimeout
        self.failInitialSchemaOnly = failInitialSchemaOnly
        self.failInactiveSchemaBaseline = failInactiveSchemaBaseline
        self.failOriginalRecheck = failOriginalRecheck
        self.failWithoutActivation = failWithoutActivation
    }

    func run(_ command: CommandSpec) throws -> CommandResult {
        if command.arguments.first == "simctl" { return try simulators.run(command) }
        func argument(_ option: String) -> String { command.arguments.firstIndex(of: option).map { command.arguments[$0 + 1] } ?? "" }
        var output = "", exit: Int32 = 0, timeout = false
        if command.arguments.contains("build-for-testing") {
            let buildSource = try String(contentsOf: command.workingDirectory.appendingPathComponent("Rules.swift"), encoding: .utf8)
            let initial = command.outputFile.lastPathComponent.hasPrefix("baseline-build")
            let hasBooted = simulators.snapshot().commands.contains { $0.first == "boot" }
            var shouldFailRuleTimeout = false
            lock.lock()
            shouldFailRuleTimeout = failFirstBuildWithRuleTimeout && !didFailRuleTimeoutBuild
            if shouldFailRuleTimeout { didFailRuleTimeoutBuild = true }
            builds.append(command)
            buildSources.append(buildSource)
            initialBuildSawBoot = initialBuildSawBoot || (initial && hasBooted)
            activeBuilds += 1; maximumActiveBuilds = max(maximumActiveBuilds, activeBuilds)
            lock.unlock()
            defer {
                let bootedDuringBuild = simulators.snapshot().commands.contains { $0.first == "boot" }
                lock.lock()
                initialBuildSawBoot = initialBuildSawBoot || (initial && bootedDuringBuild)
                activeBuilds -= 1
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.01)
            if shouldFailRuleTimeout {
                output = "error: sampleRule rule timed out in /fixture/File.swift.\n"
                exit = 65
            } else if failOriginalBuild || (failSchema && command.outputFile.lastPathComponent.hasPrefix("schema-"))
                || (failInitialSchemaOnly && command.outputFile.lastPathComponent == "schema-build.log") { exit = 65 }
            else {
                let products = URL(fileURLWithPath: argument("-derivedDataPath")).appendingPathComponent("Build/Products")
                try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
                let manifest: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 2], "TestConfigurations": [["TestTargets": [["BlueprintName": "FixtureTests", "TestBundlePath": "__TESTROOT__/FixtureTests.xctest", "TestHostBundleIdentifier": "example.fixture"]]]]]
                try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: products.appendingPathComponent("Fixture.xctestrun"))
            }
        } else {
            let file = URL(fileURLWithPath: argument("-xctestrun"))
            let text = try String(contentsOf: file, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #"<key>SWIFT_MUTATION_ID</key>\s*<string>([^<]+)</string>"#)
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            if let match, let range = Range(match.range(at: 1), in: text) {
                let id = String(text[range]), destination = argument("-destination")
                lock.lock(); active += 1; maximumActive = max(maximumActive, active)
                attempts.append((id, destination, command.timeout)); lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); active -= 1; lock.unlock()
                output = failWithoutActivation ? "Executed 2 tests\n" : "SWIFT_MUTATION_ACTIVATED:\(id)\nExecuted 2 tests\n"
                if failWithoutActivation { exit = 65 }
                timeout = timeoutFirstAttempt && command.timeout == 10
            } else {
                lock.lock(); activeBaselines += 1; maximumActiveBaselines = max(maximumActiveBaselines, activeBaselines); lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); activeBaselines -= 1; lock.unlock()
                output = "Executed \(mismatchBaseline && file.path.contains("worker-2") ? 3 : 2) tests\n"
                if failInactiveSchemaBaseline && command.outputFile.lastPathComponent.hasPrefix("inactive-schema-worker-") { exit = 65 }
                if failOriginalRecheck && command.outputFile.lastPathComponent.hasPrefix("baseline-recheck-worker-") { exit = 65 }
            }
        }
        return .init(exitCode: exit, timedOut: timeout, elapsed: 0.05, output: output, outputFile: command.outputFile)
    }
}

@Suite("Xcode scheduling", .serialized)
struct XcodeExecutionTests {
    private func campaign(_ fake: FakeXcode, workers: Int = 2, jobs: Int? = 2) throws -> XcodeMutationExecutionResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Executor \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "public func rule(_ left: Bool, _ right: Bool) -> Bool { return left && right || true }"
        try source.write(to: root.appendingPathComponent("Rules.swift"), atomically: true, encoding: .utf8)
        let config = RunConfiguration(project: .init(kind: .xcodeProject, path: "Fixture.xcodeproj", scheme: "Fixture", testTarget: "FixtureTests"), operators: [.boolean, .logical], operatorTier: "experimental", timeouts: .init(buildSeconds: 10, baselineSeconds: 10, mutantSeconds: 10), parallelism: workers)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("report/logs"), withIntermediateDirectories: true)
        let executor = XcodeMutationExecutor(configuration: config, adapter: .init(project: config.project, selection: .init(), xcodeBuildOptions: .init(jobs: jobs)),
            selection: .init(identifiers: [], allTests: true), sandbox: root, output: root.appendingPathComponent("report"), sources: ["Rules.swift": source],
            onVerdict: { _, _ in }, onCompletion: { _, _ in }, commandRunner: fake.run, cleanupRunner: fake.run,
            workerRegistryDirectory: root.appendingPathComponent("registry"))
        let candidates = SwiftMutationGenerator().generate(source: source, relativePath: "Rules.swift", operators: [.boolean, .logical])
        let result = try executor.run(template: .init(deviceType: "phone", runtime: "ios", runtimeVersion: "27", runtimeBuild: "1"), candidates: candidates, historicalDurations: [:])
        let restored = try String(contentsOf: root.appendingPathComponent("Rules.swift"), encoding: .utf8)
        #expect(restored == source)
        return result
    }

    @Test("serial and parallel workers produce identical activated verdicts")
    func parallelParity() throws {
        let serialFake = FakeXcode(), parallelFake = FakeXcode()
        let serial = try campaign(serialFake, workers: 1), parallel = try campaign(parallelFake)
        #expect(serial.records.mapValues(\.status) == parallel.records.mapValues(\.status))
        #expect(parallel.records.values.allSatisfy { $0.activated && $0.status == .survived })
        #expect(serialFake.maximumActive == 1 && parallelFake.maximumActive == 2)
        #expect(Set(parallelFake.attempts.map { $0.1 }).count == 2)
        #expect(parallel.baselineCounts == [2, 2])
        #expect(parallel.baselineRunCount == 4)
        #expect(parallel.baselineTestExecutionCount == 8)
        #expect(parallelFake.maximumActiveBaselines == 2)
        #expect(parallel.mutantTestRunCount == parallel.records.count)
        #expect(parallelFake.simulators.snapshot().devices.count == 1)
        #expect(parallelFake.initialBuildSawBoot)
        for command in parallelFake.builds {
            let index = try #require(command.arguments.firstIndex(of: "-derivedDataPath"))
            let buildPath = command.arguments[index + 1]
            #expect(!buildPath.hasPrefix(command.workingDirectory.path + "/"))
            #expect(!FileManager.default.fileExists(atPath: buildPath))
        }
    }

    @Test("parallel timeouts retry alone with twice the timeout")
    func timeoutRetry() throws {
        let fake = FakeXcode(timeoutFirstAttempt: true)
        let result = try campaign(fake)
        #expect(result.records.values.allSatisfy { $0.status == .survived && $0.message?.contains("retried in isolation") == true })
        #expect(result.mutantTestRunCount == result.records.count * 2)
        #expect(fake.attempts.filter { $0.2 == 20 }.count == result.records.count)
        #expect(fake.simulators.snapshot().devices.count == 1)
    }

    @Test("failed schemas narrow and isolated builds reuse one builder")
    func schemaFallback() throws {
        let fake = FakeXcode(failSchema: true)
        let result = try campaign(fake)
        #expect(result.records.values.allSatisfy { $0.activated && $0.status == .survived })
        #expect(result.baselineCounts.count == 2)
        #expect(result.baselineCounts == [2, 2])
        #expect(result.timings.isolatedBuildSeconds > 0)
        #expect(fake.initialBuildSawBoot)
        #expect(fake.maximumActiveBuilds == 1)
        let isolated = fake.builds.filter { $0.outputFile.lastPathComponent.hasPrefix("isolated-build-") }
        #expect(!isolated.isEmpty)
        let first = try #require(fake.builds.first)
        let baselineDataIndex = try #require(first.arguments.firstIndex(of: "-derivedDataPath"))
        #expect(fake.maximumActive == 1)
        for (index, command) in fake.builds.enumerated() where command.outputFile.lastPathComponent.hasPrefix("isolated-build-") {
            let dataIndex = try #require(command.arguments.firstIndex(of: "-derivedDataPath"))
            #expect(command.workingDirectory == first.workingDirectory)
            #expect(command.arguments[dataIndex + 1] == first.arguments[baselineDataIndex + 1])
            #expect(!FileManager.default.fileExists(atPath: command.arguments[dataIndex + 1]))
            let id = String(command.outputFile.deletingPathExtension().lastPathComponent.dropFirst("isolated-build-".count))
            for other in result.records.keys {
                #expect(fake.buildSources[index].contains(other) == (other == id))
            }
        }
    }

    @Test("failed original builds abort and clean simulators booted during the build")
    func failedBuildDoesNotBoot() throws {
        let fake = FakeXcode(failOriginalBuild: true)
        do {
            _ = try campaign(fake)
            Issue.record("Expected the original build to fail")
        } catch let error as MutationEngineError {
            guard case .baselineBuildFailed = error else { Issue.record("Wrong error: \(error)"); return }
            #expect(error.description.contains("tests did not start"))
        }
        #expect(fake.attempts.isEmpty)
        #expect(fake.simulators.snapshot().commands.contains { $0.first == "boot" })
        #expect(fake.simulators.snapshot().devices.count == 1)
        #expect(fake.builds.count == 1)
        for command in fake.builds {
            let index = try #require(command.arguments.firstIndex(of: "-derivedDataPath"))
            #expect(!FileManager.default.fileExists(atPath: command.arguments[index + 1]))
        }
    }

    @Test("Build rule timeouts retry once with one job and the same DerivedData")
    func buildRuleTimeoutRetriesSerially() throws {
        let fake = FakeXcode(failFirstBuildWithRuleTimeout: true)
        let result = try campaign(fake, workers: 1)
        #expect(result.timings.originalBuildSeconds == 0.10)
        #expect(result.timings.xcodeAttempts?.filter { $0.phase == "originalBuild" }.map(\.exitCode) == [65, 0])
        #expect(abs(result.timings.mutantRunSeconds - Double(result.mutantTestRunCount) * 0.05) < 0.0001)

        #expect(fake.builds.count >= 2)
        let first = fake.builds[0]
        let retry = fake.builds[1]
        #expect(first.outputFile.lastPathComponent == "baseline-build.log")
        #expect(retry.outputFile.lastPathComponent == "baseline-build-rule-timeout-retry.log")
        let firstJobs = try #require(first.arguments.firstIndex(of: "-jobs"))
        let retryJobs = try #require(retry.arguments.firstIndex(of: "-jobs"))
        #expect(first.arguments[first.arguments.index(after: firstJobs)] == "2")
        #expect(retry.arguments[retry.arguments.index(after: retryJobs)] == "1")
        let firstDerivedData = try #require(first.arguments.firstIndex(of: "-derivedDataPath"))
        let retryDerivedData = try #require(retry.arguments.firstIndex(of: "-derivedDataPath"))
        #expect(first.arguments[first.arguments.index(after: firstDerivedData)] == retry.arguments[retry.arguments.index(after: retryDerivedData)])
        #expect(fake.builds.filter { $0.outputFile.lastPathComponent.hasSuffix("-rule-timeout-retry.log") }.count == 1)
        let reportErrors = """
        error: ruleOne rule timed out in FileOne.swift.
        error: ruleTwo rule timed out in FileTwo.swift.
        """
        #expect(XcodeMutationExecutor.failedOnlyOnBuildRuleTimeouts(reportErrors))
        #expect(!XcodeMutationExecutor.failedOnlyOnBuildRuleTimeouts("error: compiler failed\nerror: ruleOne rule timed out in File.swift"))
    }

    @Test("automatic Xcode build jobs retry once with one job")
    func autoBuildJobs() throws {
        let fake = FakeXcode(failFirstBuildWithRuleTimeout: true)
        _ = try campaign(fake, workers: 1, jobs: nil)
        #expect(!fake.builds[0].arguments.contains("-jobs"))
        let jobs = try #require(fake.builds[1].arguments.firstIndex(of: "-jobs"))
        #expect(fake.builds[1].arguments[jobs + 1] == "1")
    }

    @Test("different baseline counts abort before any mutant runs and clean both workers")
    func baselineMismatch() throws {
        let fake = FakeXcode(mismatchBaseline: true)
        #expect(throws: MutationEngineError.self) { try campaign(fake) }
        #expect(fake.attempts.isEmpty)
        #expect(fake.simulators.snapshot().devices.count == 1)
    }

    @Test("a rebuilt inactive schema must pass before its mutants run")
    func inactiveSchemaBaseline() throws {
        let fake = FakeXcode(failInitialSchemaOnly: true, failInactiveSchemaBaseline: true)
        do {
            _ = try campaign(fake, workers: 1)
            Issue.record("Expected the inactive schema baseline to fail")
        } catch let error as MutationEngineError {
            #expect(error.description.contains("Inactive schema changes the selected tests for mutant"))
        }
        #expect(fake.attempts.isEmpty)
    }

    @Test("a first-build inactive schema failure is diagnosed before mutant tests")
    func initialInactiveSchemaBaseline() throws {
        let fake = FakeXcode(failInactiveSchemaBaseline: true)
        do {
            _ = try campaign(fake, workers: 1)
            Issue.record("Expected the inactive schema baseline to fail")
        } catch let error as MutationEngineError {
            #expect(error.description.contains("Rules.swift:1"))
            #expect(error.description.contains("Inactive schema changes the selected tests"))
        }
        #expect(fake.attempts.isEmpty)
        #expect(fake.builds.first?.outputFile.lastPathComponent == "baseline-build.log")
        #expect(fake.simulators.snapshot().devices.count == 1)
    }

    @Test("an unstable original baseline is reported before blaming the schema")
    func originalBaselineFlake() throws {
        let fake = FakeXcode(failInactiveSchemaBaseline: true, failOriginalRecheck: true)
        do {
            _ = try campaign(fake, workers: 1)
            Issue.record("Expected an unstable original baseline")
        } catch let error as MutationEngineError {
            #expect(error.description.contains("Original tests did not pass consistently"))
        }
        #expect(fake.attempts.isEmpty)
        #expect(fake.simulators.snapshot().devices.count == 1)
    }

    @Test("an unactivated test failure is retried once before stopping")
    func unactivatedFailureRetriesOnceThenStops() throws {
        let fake = FakeXcode(failWithoutActivation: true)
        do {
            _ = try campaign(fake, workers: 1)
            Issue.record("Expected an integrity failure")
        } catch let error as MutationEngineError {
            #expect(error.description.contains("failed again after an unactivated attempt"))
        }
        #expect(fake.attempts.count == 2)
    }
}
