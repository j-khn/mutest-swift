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
    private(set) var initialBuildSawBoot = false
    private(set) var maximumActiveBuilds = 0
    private var activeBuilds = 0
    let failSchema: Bool
    let failOriginalBuild: Bool
    let timeoutFirstAttempt: Bool
    let mismatchBaseline: Bool
    init(failSchema: Bool = false, failOriginalBuild: Bool = false, timeoutFirstAttempt: Bool = false, mismatchBaseline: Bool = false) {
        self.failSchema = failSchema; self.timeoutFirstAttempt = timeoutFirstAttempt; self.mismatchBaseline = mismatchBaseline
        self.failOriginalBuild = failOriginalBuild
    }

    func run(_ command: CommandSpec) throws -> CommandResult {
        if command.arguments.first == "simctl" { return try simulators.run(command) }
        func argument(_ option: String) -> String { command.arguments.firstIndex(of: option).map { command.arguments[$0 + 1] } ?? "" }
        var output = "", exit: Int32 = 0, timeout = false
        if command.arguments.contains("build-for-testing") {
            let initial = ["schema-build.log", "baseline-build.log"].contains(command.outputFile.lastPathComponent)
            let hasBooted = simulators.snapshot().commands.contains { $0.first == "boot" }
            lock.lock()
            builds.append(command)
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
            if failOriginalBuild || (failSchema && command.outputFile.lastPathComponent.hasPrefix("schema-")) { exit = 65 }
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
                output = "SWIFT_MUTATION_ACTIVATED:\(id)\nExecuted 2 tests\n"
                timeout = timeoutFirstAttempt && command.timeout == 10
            } else {
                lock.lock(); activeBaselines += 1; maximumActiveBaselines = max(maximumActiveBaselines, activeBaselines); lock.unlock()
                Thread.sleep(forTimeInterval: 0.05)
                lock.lock(); activeBaselines -= 1; lock.unlock()
                output = "Executed \(mismatchBaseline && file.path.contains("worker-2") ? 3 : 2) tests\n"
            }
        }
        return .init(exitCode: exit, timedOut: timeout, elapsed: 0.05, output: output, outputFile: command.outputFile)
    }
}

@Suite("Xcode scheduling", .serialized)
struct XcodeExecutionTests {
    private func campaign(_ fake: FakeXcode, workers: Int = 2) throws -> XcodeMutationExecutionResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Executor \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "public func rule(_ left: Bool, _ right: Bool) -> Bool { return left && right || true }"
        try source.write(to: root.appendingPathComponent("Rules.swift"), atomically: true, encoding: .utf8)
        let config = RunConfiguration(project: .init(kind: .xcodeProject, path: "Fixture.xcodeproj", scheme: "Fixture", testTarget: "FixtureTests"), operators: [.boolean, .logical], operatorTier: "experimental", timeouts: .init(buildSeconds: 10, baselineSeconds: 10, mutantSeconds: 10), parallelism: workers)
        let executor = XcodeMutationExecutor(configuration: config, adapter: .init(project: config.project, selection: .init()),
            selection: .init(identifiers: [], allTests: true), sandbox: root, output: root.appendingPathComponent("report"), sources: ["Rules.swift": source],
            createSandbox: {
                let path = root.appendingPathComponent("isolated-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                return ProjectSandbox(container: path, root: path, localPackages: [])
            }, onVerdict: { _, _ in }, onCompletion: { _, _ in }, commandRunner: fake.run, cleanupRunner: fake.run,
            workerRegistryDirectory: root.appendingPathComponent("registry"))
        let candidates = SwiftMutationGenerator().generate(source: source, relativePath: "Rules.swift", operators: [.boolean, .logical])
        return try executor.run(template: .init(deviceType: "phone", runtime: "ios", runtimeVersion: "27", runtimeBuild: "1"), candidates: candidates, historicalDurations: [:])
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
        #expect(parallelFake.maximumActiveBaselines == 2)
        #expect(parallel.mutantTestRunCount == parallel.records.count)
        #expect(parallelFake.simulators.snapshot().devices.count == 1)
        #expect(!parallelFake.initialBuildSawBoot)
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

    @Test("failed schemas narrow and isolated builds use independent worker roots")
    func schemaFallback() throws {
        let fake = FakeXcode(failSchema: true)
        let result = try campaign(fake)
        #expect(result.records.values.allSatisfy { $0.activated && $0.status == .survived })
        #expect(result.baselineCounts.count == 2)
        #expect(result.timings.isolatedBuildSeconds > 0)
        #expect(!fake.initialBuildSawBoot)
        #expect(fake.maximumActiveBuilds == 1)
        let isolated = fake.builds.filter { $0.outputFile.lastPathComponent.hasPrefix("isolated-build-") }
        #expect(!isolated.isEmpty)
        for command in isolated {
            let index = try #require(command.arguments.firstIndex(of: "-derivedDataPath"))
            #expect(!command.arguments[index + 1].hasPrefix(command.workingDirectory.path + "/"))
            #expect(!FileManager.default.fileExists(atPath: command.arguments[index + 1]))
        }
    }

    @Test("failed original builds abort without booting simulators and remove build files")
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
        #expect(!fake.simulators.snapshot().commands.contains { $0.first == "boot" })
        #expect(fake.simulators.snapshot().devices.count == 1)
        #expect(fake.builds.count == 2)
        for command in fake.builds {
            let index = try #require(command.arguments.firstIndex(of: "-derivedDataPath"))
            #expect(!FileManager.default.fileExists(atPath: command.arguments[index + 1]))
        }
    }

    @Test("different baseline counts abort before any mutant runs and clean both workers")
    func baselineMismatch() throws {
        let fake = FakeXcode(mismatchBaseline: true)
        #expect(throws: MutationEngineError.self) { try campaign(fake) }
        #expect(fake.attempts.isEmpty)
        #expect(fake.simulators.snapshot().devices.count == 1)
    }
}
