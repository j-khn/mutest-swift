import Foundation
import Testing
import MutationTestingSpec
@testable import SwiftMutationTesting

final class FakeSimulators: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: String] = ["user-simulator": "My Simulator"]
    private var commands: [[String]] = []
    var failBoot = false
    private var launchctlOutput = ""
    func setLaunchctlOutput(_ output: String) { lock.lock(); launchctlOutput = output; lock.unlock() }
    func run(_ command: CommandSpec) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        let args = Array(command.arguments.dropFirst())
        commands.append(args)
        var output = "", code: Int32 = 0
        switch args.first {
        case "create":
            output = UUID().uuidString; devices[output] = args[1]
        case "clone":
            output = UUID().uuidString; devices[output] = args[2]
        case "list":
            let root = ["devices": ["runtime": devices.map { ["udid": $0.key, "name": $0.value] }]]
            output = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
        case "boot" where failBoot: code = 1
        case "delete": devices.removeValue(forKey: args[1])
        case "spawn": output = launchctlOutput
        default: break
        }
        return .init(exitCode: code, timedOut: false, elapsed: 0, output: output, outputFile: command.outputFile)
    }
    func snapshot() -> (devices: [String: String], commands: [[String]]) {
        lock.lock(); defer { lock.unlock() }; return (devices, commands)
    }
}

@Suite("Xcode worker isolation", .serialized)
struct XcodeWorkerTests {
    private var template: XcodeSimulatorTemplate {
        .init(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2", runtimeVersion: "27.2", runtimeBuild: "test-build")
    }
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Xcode workers \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func inventory() throws -> SimulatorInventory {
        let data = #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-2","version":"27.2","buildversion":"A","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","version":"26.0","buildversion":"B","isAvailable":true}],"devicetypes":[{"name":"iPhone 17","identifier":"phone"}],"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"udid":"new","name":"iPhone 17","isAvailable":true,"deviceTypeIdentifier":"phone"}],"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"udid":"old","name":"iPhone 17","isAvailable":true,"deviceTypeIdentifier":"phone"}]}}"#
        return try JSONDecoder().decode(SimulatorInventory.self, from: Data(data.utf8))
    }

    @Test("requires an unambiguous simulator and fingerprints runtime builds")
    func destinations() throws {
        let inventory = try inventory()
        #expect(throws: MutationEngineError.self) { try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,name=iPhone 17", inventory: inventory) }
        #expect(throws: MutationEngineError.self) { try XcodeSimulatorTemplate.resolve(destination: nil, inventory: inventory) }
        #expect(throws: MutationEngineError.self) { try XcodeSimulatorTemplate.resolve(destination: "generic/platform=iOS Simulator", inventory: inventory) }
        let latestValue = try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,name=iPhone 17,OS=latest", inventory: inventory)
        let exactValue = try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,id=new", inventory: inventory)
        let old = try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,id=old", inventory: inventory)
        let latest = try #require(latestValue), exact = try #require(exactValue)
        #expect(latest.fingerprint == exact.fingerprint)
        #expect(latest.fingerprint != old?.fingerprint)
        #expect(try XcodeSimulatorTemplate.resolve(destination: "platform=macOS", inventory: inventory) == nil)
    }

    @Test("workers have exclusive simulators and cleanup never touches the user's simulator")
    func ownership() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators()
        let pool = try XcodeSimulatorPool(template: template, count: 2, output: root, run: fake.run, teardownRun: fake.run)
        _ = try pool.waitUntilReady()
        let first = pool.acquire(), second = pool.acquire()
        #expect(first.simulatorID != second.simulatorID)
        #expect(first.directory != second.directory)
        pool.release(second); pool.release(first)
        #expect(pool.cleanup().isEmpty)
        let snapshot = fake.snapshot()
        #expect(snapshot.devices == ["user-simulator": "My Simulator"])
        #expect(!snapshot.commands.contains { ["delete", "shutdown", "terminate"].contains($0.first ?? "") && $0.dropFirst().contains("user-simulator") })
    }

    @Test("recovers an abandoned unlocked pool and keeps a live pool")
    func staleRecovery() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators()
        var abandoned: XcodeSimulatorPool? = try XcodeSimulatorPool(template: template, count: 1, output: root, run: fake.run, teardownRun: fake.run)
        _ = try abandoned?.waitUntilReady()
        let abandonedID = try #require(abandoned?.workers.first?.simulatorID)
        abandoned = nil
        let live = try XcodeSimulatorPool(template: template, count: 1, output: root, run: fake.run, teardownRun: fake.run)
        _ = try live.waitUntilReady()
        #expect(fake.snapshot().devices[abandonedID] == nil)
        let another = try XcodeSimulatorPool(template: template, count: 1, output: root, run: fake.run, teardownRun: fake.run)
        _ = try another.waitUntilReady()
        #expect(fake.snapshot().devices[live.workers[0].simulatorID] != nil)
        #expect(another.cleanup().isEmpty)
        #expect(live.cleanup().isEmpty)
    }

    @Test("a failed boot still allows bounded owned-device cleanup")
    func startupFailure() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators(); fake.failBoot = true
        let pool = try XcodeSimulatorPool(template: template, count: 2, output: root, bootTimeout: 1, run: fake.run, teardownRun: fake.run)
        #expect(throws: MutationEngineError.self) { try pool.waitUntilReady() }
        #expect(pool.cleanup().isEmpty)
        #expect(fake.snapshot().devices.count == 1)
    }

    @Test("ownership recovery survives removal of a previous Actions report folder")
    func persistentRecovery() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators(), registry = root.appendingPathComponent("registry")
        let oldOutput = root.appendingPathComponent("old-checkout/reports")
        var abandoned: XcodeSimulatorPool? = try XcodeSimulatorPool(template: template, count: 1, output: oldOutput,
            registryDirectory: registry, run: fake.run, teardownRun: fake.run)
        _ = try abandoned?.waitUntilReady()
        let oldID = try #require(abandoned?.workers.first?.simulatorID)
        abandoned = nil
        try FileManager.default.removeItem(at: oldOutput)
        let recovered = try XcodeSimulatorPool(template: template, count: 1, output: root.appendingPathComponent("new-checkout/reports"),
            registryDirectory: registry, run: fake.run, teardownRun: fake.run)
        _ = try recovered.waitUntilReady()
        #expect(fake.snapshot().devices[oldID] == nil)
        #expect(recovered.cleanup().isEmpty)
    }

    @Test("cloning a shut-down template never changes or deletes that template")
    func cloneTemplate() throws {
        var inventory = try inventory()
        var device = try #require(inventory.devices[template.runtime]?.first)
        device.state = "Shutdown"; inventory.devices[template.runtime] = [device]
        let shutdown = try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,id=new", inventory: inventory)
        #expect(shutdown?.cloneSourceID == "new")
        device.state = "Booted"; inventory.devices[template.runtime] = [device]
        let booted = try XcodeSimulatorTemplate.resolve(destination: "platform=iOS Simulator,id=new", inventory: inventory)
        #expect(booted?.cloneSourceID == nil)
        #expect(shutdown?.fingerprint != booted?.fingerprint)
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators()
        var configured = template
        configured.cloneSourceID = "user-simulator"
        let pool = try XcodeSimulatorPool(template: configured, count: 2, output: root, run: fake.run, teardownRun: fake.run)
        _ = try pool.waitUntilReady()
        #expect(pool.cleanup().isEmpty)
        let result = fake.snapshot()
        #expect(result.devices == ["user-simulator": "My Simulator"])
        #expect(result.commands.filter { $0.first == "clone" }.count == 2)
        #expect(!result.commands.contains { ["boot", "shutdown", "delete"].contains($0.first ?? "") && $0.dropFirst().contains("user-simulator") })
    }

    @Test("stopped test-host services do not force an unnecessary simulator reboot")
    func testHostCleanup() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeSimulators()
        let pool = try XcodeSimulatorPool(template: template, count: 1, output: root, run: fake.run, teardownRun: fake.run)
        _ = try pool.waitUntilReady()
        fake.setLaunchctlOutput("PID Status Label\n- 0 UIKitApplication:example.fixture\n")
        try pool.sanitize(pool.workers[0], hostBundleIDs: ["example.fixture"])
        #expect(fake.snapshot().commands.filter { $0.first == "boot" }.count == 1)
        fake.setLaunchctlOutput("PID Status Label\n42 0 UIKitApplication:example.fixture\n")
        try pool.sanitize(pool.workers[0], hostBundleIDs: ["example.fixture"])
        #expect(fake.snapshot().commands.filter { $0.first == "boot" }.count == 2)
        #expect(pool.cleanup().isEmpty)
    }

    @Test("Xcode product copies preserve test plans and isolate per-attempt mutation variables")
    func artifacts() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("builder/Build/Products")
        try FileManager.default.createDirectory(at: products.appendingPathComponent("Debug-iphonesimulator/Fixture.app"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["TestPlan": ["Name": "Default", "IsDefault": true], "TestConfigurations": [["Name": "Tests", "TestTargets": [["BlueprintName": "FixtureTests", "TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/FixtureTests.xctest", "TestHostPath": products.appendingPathComponent("Debug-iphonesimulator/Fixture.app").path, "TestHostBundleIdentifier": "example.Fixture", "EnvironmentVariables": ["KEEP": "yes", "SWIFT_MUTATION_ID": "stale"]]]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: products.appendingPathComponent("Fixture.xctestrun"))
        let first = try XcodeTestArtifacts.snapshot(derivedData: root.appendingPathComponent("builder"), into: root.appendingPathComponent("worker1"), testTarget: "FixtureTests")
        let second = try XcodeTestArtifacts.snapshot(derivedData: root.appendingPathComponent("builder"), into: root.appendingPathComponent("worker2"), testTarget: "FixtureTests")
        let left = try String(contentsOf: first.invocationManifest(environment: ["SWIFT_MUTATION_ID": "left-id"]), encoding: .utf8)
        let right = try String(contentsOf: second.invocationManifest(environment: ["SWIFT_MUTATION_ID": "right-id"]), encoding: .utf8)
        let inactive = try String(contentsOf: first.invocationManifest(environment: [:]), encoding: .utf8)
        #expect(left.contains("left-id") && !left.contains("right-id") && !left.contains("stale"))
        #expect(right.contains("right-id") && !right.contains("left-id"))
        #expect(!inactive.contains("SWIFT_MUTATION_ID"))
        #expect(left.contains("KEEP") && left.contains("__TESTROOT__"))
        #expect(left.contains(first.products.path) && !left.contains(products.path))
        #expect(first.hostBundleIDs == ["example.Fixture"])
    }

    @Test("worker Xcode commands retain exact test scope and disable extra Xcode workers")
    func adapter() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let adapter = NativeTestAdapter(project: .init(kind: .xcodeWorkspace, path: "Fixture.xcworkspace", scheme: "Fixture", testTarget: "FixtureTests"), selection: .init())
        let context = XcodeTestExecutionContext(destination: "platform=iOS Simulator,id=owned", derivedDataPath: root.appendingPathComponent("workerData"), testRunFile: root.appendingPathComponent("attempt.xctestrun"), resultBundlePath: root.appendingPathComponent("result.xcresult"))
        let command = try adapter.command(root: root, phase: .testWithoutBuilding, resolved: .init(identifiers: ["FixtureTests/RuleTests/testRule()"], allTests: false), environment: [:], timeout: 30, output: root.appendingPathComponent("attempt.log"), xcodeContext: context)
        #expect(command.arguments.contains("-xctestrun"))
        #expect(!command.arguments.contains("-workspace") && !command.arguments.contains("-scheme"))
        #expect(command.arguments.contains("-only-testing:FixtureTests/RuleTests/testRule()"))
        let index = try #require(command.arguments.firstIndex(of: "-parallel-testing-enabled"))
        #expect(command.arguments[index + 1] == "NO")
        #expect(command.arguments.contains(context.derivedDataPath.path))
        #expect(command.arguments.contains(context.resultBundlePath!.path))
    }

    @Test("baseline counts add both frameworks without adding nested XCTest totals twice")
    func testCounts() {
        #expect(TestExecutionCount.parse("Executed 1 test\nExecuted 3 tests\nExecuted 3 tests\nTest run with 4 tests in 1 suite passed") == 7)
        #expect(TestExecutionCount.parse("Build complete!") == nil)
        #expect(TestExecutionCount.parse("Test run with 0 tests passed") == 0)
    }
}
