import Foundation
import Testing
import MutationTestingSpec
@testable import SwiftMutationTesting

private final class FakeXcode: @unchecked Sendable {
    let simulators = FakeSimulators()
    private let lock = NSLock()
    private var active = 0
    private var activeBaselines = 0
    private(set) var maximumActive = 0
    private(set) var maximumActiveBaselines = 0
    private(set) var attempts: [(String, String, TimeInterval)] = []
    let failSchema: Bool
    let timeoutFirstAttempt: Bool
    let mismatchBaseline: Bool
    init(failSchema: Bool = false, timeoutFirstAttempt: Bool = false, mismatchBaseline: Bool = false) {
        self.failSchema = failSchema; self.timeoutFirstAttempt = timeoutFirstAttempt; self.mismatchBaseline = mismatchBaseline
    }

    func run(_ command: CommandSpec) throws -> CommandResult {
        if command.arguments.first == "simctl" { return try simulators.run(command) }
        func argument(_ option: String) -> String { command.arguments.firstIndex(of: option).map { command.arguments[$0 + 1] } ?? "" }
        var output = "", exit: Int32 = 0, timeout = false
        if command.arguments.contains("build-for-testing") {
            if failSchema && command.outputFile.lastPathComponent.hasPrefix("schema-") { exit = 65 }
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
                return path
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
        let result = try campaign(FakeXcode(failSchema: true))
        #expect(result.records.values.allSatisfy { $0.activated && $0.status == .survived })
        #expect(result.baselineCounts.count == 2)
        #expect(result.timings.isolatedBuildSeconds > 0)
    }

    @Test("different baseline counts abort before any mutant runs and clean both workers")
    func baselineMismatch() throws {
        let fake = FakeXcode(mismatchBaseline: true)
        #expect(throws: MutationEngineError.self) { try campaign(fake) }
        #expect(fake.attempts.isEmpty)
        #expect(fake.simulators.snapshot().devices.count == 1)
    }
}
