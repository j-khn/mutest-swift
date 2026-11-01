import Foundation
import MutationTestingSpec
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

typealias XcodeCommandRunner = @Sendable (CommandSpec) throws -> CommandResult

func mutationLog(_ message: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data(("[mutest-swift] " + message + "\n").utf8))
}

struct SimulatorInventory: Decodable {
    struct Device: Decodable {
        var udid: String
        var name: String
        var isAvailable: Bool?
        var deviceTypeIdentifier: String?
        var state: String?
    }
    struct Runtime: Decodable {
        var identifier: String
        var version: String
        var buildversion: String?
        var isAvailable: Bool?
    }
    struct DeviceType: Decodable { var name: String; var identifier: String }
    var devices: [String: [Device]]
    var runtimes: [Runtime]
    var devicetypes: [DeviceType]
}

struct XcodeSimulatorTemplate: Sendable {
    var deviceType: String
    var runtime: String
    var runtimeVersion: String
    var runtimeBuild: String
    var cloneSourceID: String? = nil
    var fingerprint: String { "\(deviceType)|\(runtime)|\(runtimeVersion)|\(runtimeBuild)|\(cloneSourceID == nil ? "fresh" : "clone")" }

    static func resolve(destination: String?, inventory: SimulatorInventory) throws -> Self? {
        guard let destination, !destination.isEmpty else {
            throw MutationEngineError.invalidProject("Xcode mutation testing requires --destination. Supply an installed iOS Simulator name or ID.")
        }
        var fields: [String: String] = [:]
        for part in destination.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, fields[pair[0]] == nil else { throw MutationEngineError.invalidProject("Invalid destination: \(destination)") }
            fields[pair[0]] = pair[1]
        }
        guard fields["platform"] == "iOS Simulator" else {
            if destination.contains("iOS Simulator") { throw MutationEngineError.invalidProject("Use a concrete iOS Simulator destination, not a generic destination.") }
            return nil
        }
        var matches: [(SimulatorInventory.Device, SimulatorInventory.Runtime)] = []
        let runtimes = inventory.runtimes.filter { $0.identifier.contains(".iOS-") && $0.isAvailable != false }
        let selectedVersion = fields["OS"] == "latest"
            ? runtimes.map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedAscending }.last
            : fields["OS"]
        for runtime in runtimes where selectedVersion == nil || selectedVersion == runtime.version {
            for device in inventory.devices[runtime.identifier] ?? [] where device.isAvailable != false {
                if let id = fields["id"], device.udid.caseInsensitiveCompare(id) != .orderedSame { continue }
                if let name = fields["name"], device.name != name { continue }
                if fields["id"] != nil || fields["name"] != nil { matches.append((device, runtime)) }
            }
        }
        guard matches.count == 1, let (device, runtime) = matches.first else {
            throw MutationEngineError.invalidProject("Destination '\(destination)' matched \(matches.count) available iOS Simulators. Specify a unique id or name and OS.")
        }
        guard let type = device.deviceTypeIdentifier ?? inventory.devicetypes.first(where: { $0.name == device.name })?.identifier else {
            throw MutationEngineError.invalidProject("Cannot determine the device type for simulator '\(device.name)'.")
        }
        return Self(deviceType: type, runtime: runtime.identifier, runtimeVersion: runtime.version, runtimeBuild: runtime.buildversion ?? "", cloneSourceID: device.state == "Shutdown" ? device.udid : nil)
    }

    static func load(destination: String?, logs: URL) throws -> Self? {
        guard let destination, !destination.isEmpty else {
            throw MutationEngineError.invalidProject("Xcode mutation testing requires --destination.")
        }
        if !destination.contains("iOS Simulator") {
            mutationLog("Xcode destination is not an iOS Simulator; using one worker.")
            return nil
        }
        let result = try ProcessRunner().run(.init(executable: "/usr/bin/xcrun", arguments: ["simctl", "list", "-j"], workingDirectory: logs, timeout: 30, outputFile: logs.appendingPathComponent("simulator-inventory.log")))
        guard !result.timedOut, result.exitCode == 0, let data = result.output.data(using: .utf8) else {
            throw MutationEngineError.invalidProject("Cannot list installed simulators. See \(result.outputFile.path)")
        }
        return try resolve(destination: destination, inventory: JSONDecoder().decode(SimulatorInventory.self, from: data))
    }
}

final class XcodeSimulatorWorker: @unchecked Sendable {
    let number: Int
    let simulatorID: String
    let directory: URL
    var artifacts: XcodeTestArtifacts?
    var isolatedRoot: URL?
    init(number: Int, simulatorID: String, directory: URL) {
        self.number = number; self.simulatorID = simulatorID; self.directory = directory
    }
    var destination: String { "platform=iOS Simulator,id=\(simulatorID)" }
}

/// Owns only devices listed in its locked manifest. Different campaigns and the user's
/// original simulator are never shut down, erased, or deleted by this pool.
final class XcodeSimulatorPool: @unchecked Sendable {
    private struct OwnedDevice: Codable { var name: String; var id: String? }
    private struct Ownership: Codable { var runID: String; var devices: [OwnedDevice] }
    let workers: [XcodeSimulatorWorker]
    private let directory: URL
    private let logs: URL
    private let run: XcodeCommandRunner
    private let teardownRun: XcodeCommandRunner
    private let condition = NSCondition()
    private var available: [XcodeSimulatorWorker]
    private let bootQueue = OperationQueue()
    private let bootLock = NSLock()
    private var bootErrors: [any Error] = []
    private var lastReadyAt: Date?
    private let startedAt: Date
    private var ownership: Ownership
    private var lockFD: Int32
    private var closed = false
    private let bootTimeout: TimeInterval

    init(template: XcodeSimulatorTemplate, count: Int, output: URL, bootTimeout: TimeInterval = 120,
         run: @escaping XcodeCommandRunner = { try ProcessRunner().run($0) },
         teardownRun: @escaping XcodeCommandRunner = { try ProcessRunner(ignoresCancellation: true).run($0) }) throws {
        let manager = FileManager.default
        let parent = output.appendingPathComponent("workers")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let logs = output.appendingPathComponent("logs/simulators")
        try manager.createDirectory(at: logs, withIntermediateDirectories: true)
        try Self.recoverStalePools(parent: parent, logs: logs, run: teardownRun)
        let runID = UUID().uuidString
        let directory = parent.appendingPathComponent(runID)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if fd >= 0 { _ = close(fd) }
            throw MutationEngineError.invalidProject("Cannot lock simulator ownership directory: \(directory.path)")
        }
        var ownership = Ownership(runID: runID, devices: [])
        var workers: [XcodeSimulatorWorker] = []
        let startedAt = Date()
        do {
            for number in 1...max(1, count) {
                let name = "mutest-\(runID)-worker-\(number)"
                ownership.devices.append(.init(name: name))
                try Self.persist(ownership, in: directory)
                let arguments = template.cloneSourceID.map { ["clone", $0, name] } ?? ["create", name, template.deviceType, template.runtime]
                let result = try Self.execute(arguments, logs: logs, timeout: 60, run: run)
                let id = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.exitCode == 0, !result.timedOut, UUID(uuidString: id) != nil else {
                    throw MutationEngineError.invalidProject("Could not create Xcode worker \(number). See \(result.outputFile.path)")
                }
                ownership.devices[number - 1].id = id
                try Self.persist(ownership, in: directory)
                workers.append(.init(number: number, simulatorID: id, directory: directory.appendingPathComponent("worker-\(number)")))
            }
        } catch {
            _ = try? Self.removeOwned(ownership, directory: directory, logs: logs, run: teardownRun)
            _ = flock(fd, LOCK_UN); _ = close(fd)
            throw error
        }
        self.directory = directory; self.logs = logs; self.run = run; self.teardownRun = teardownRun
        self.ownership = ownership; self.workers = workers; self.available = workers
        self.lockFD = fd; self.startedAt = startedAt; self.bootTimeout = bootTimeout
        bootQueue.maxConcurrentOperationCount = workers.count
        for worker in workers {
            bootQueue.addOperation { [weak self] in
                guard let self else { return }
                do {
                    try self.boot(worker)
                    self.bootLock.lock(); self.lastReadyAt = Date(); self.bootLock.unlock()
                    mutationLog("Xcode worker \(worker.number) ready: \(worker.simulatorID)")
                } catch {
                    self.bootLock.lock(); self.bootErrors.append(error); self.bootLock.unlock()
                }
            }
        }
    }

    deinit {
        if lockFD >= 0 { _ = flock(lockFD, LOCK_UN); _ = close(lockFD) }
    }

    func waitUntilReady() throws -> TimeInterval {
        bootQueue.waitUntilAllOperationsAreFinished()
        bootLock.lock(); defer { bootLock.unlock() }
        if let error = bootErrors.first { throw error }
        return (lastReadyAt ?? Date()).timeIntervalSince(startedAt)
    }

    func acquire() -> XcodeSimulatorWorker {
        condition.lock(); defer { condition.unlock() }
        while available.isEmpty { condition.wait() }
        return available.removeFirst()
    }

    func release(_ worker: XcodeSimulatorWorker) {
        condition.lock(); available.append(worker); condition.signal(); condition.unlock()
    }

    func reset(_ worker: XcodeSimulatorWorker) throws {
        _ = try Self.execute(["shutdown", worker.simulatorID], logs: logs, timeout: 15, run: teardownRun)
        try boot(worker)
    }

    func sanitize(_ worker: XcodeSimulatorWorker, hostBundleIDs: [String]) throws {
        if ProcessRunner.cancellationRequested { return } // Campaign teardown shuts down this whole owned device.
        guard !hostBundleIDs.isEmpty else { try reset(worker); return }
        for host in hostBundleIDs {
            _ = try Self.execute(["terminate", worker.simulatorID, host], logs: logs, timeout: 15, run: teardownRun)
        }
        let probe = try Self.execute(["spawn", worker.simulatorID, "launchctl", "list"], logs: logs, timeout: 15, run: teardownRun)
        let runningHosts = probe.output.split(whereSeparator: \.isNewline).contains { line in
            guard let pid = line.split(whereSeparator: \.isWhitespace).first.flatMap({ Int($0) }), pid > 0 else { return false }
            return hostBundleIDs.contains { line.contains($0) }
        }
        if probe.exitCode != 0 || probe.timedOut || runningHosts { try reset(worker) }
    }

    func cleanup() -> [IntegrityWarning] {
        guard !closed else { return [] }
        closed = true
        bootQueue.waitUntilAllOperationsAreFinished()
        defer { _ = flock(lockFD, LOCK_UN); _ = close(lockFD); lockFD = -1 }
        do {
            let failures = try Self.removeOwned(ownership, directory: directory, logs: logs, run: teardownRun)
            return failures.map { .init(code: "simulatorCleanupFailed", message: $0) }
        } catch { return [.init(code: "simulatorCleanupFailed", message: "\(error). Ownership retained at \(directory.path).") ] }
    }

    private func boot(_ worker: XcodeSimulatorWorker) throws {
        let start = Date()
        let boot = try Self.execute(["boot", worker.simulatorID], logs: logs, timeout: bootTimeout, run: run)
        guard !boot.timedOut, boot.exitCode == 0 else { throw MutationEngineError.invalidProject("Worker \(worker.number) could not boot: \(boot.outputFile.path)") }
        let ready = try Self.execute(["bootstatus", worker.simulatorID, "-b"], logs: logs, timeout: max(0.1, bootTimeout - Date().timeIntervalSince(start)), run: run)
        guard !ready.timedOut, ready.exitCode == 0 else { throw MutationEngineError.invalidProject("Worker \(worker.number) was not ready within \(Int(bootTimeout)) seconds: \(ready.outputFile.path)") }
    }

    private static func execute(_ arguments: [String], logs: URL, timeout: TimeInterval, run: XcodeCommandRunner) throws -> CommandResult {
        try run(.init(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments, workingDirectory: logs, timeout: timeout,
                      outputFile: logs.appendingPathComponent("\(arguments.first ?? "command")-\(UUID().uuidString).log")))
    }

    private static func persist(_ ownership: Ownership, in directory: URL) throws {
        try JSONEncoder().encode(ownership).write(to: directory.appendingPathComponent("ownership.json"), options: .atomic)
    }

    private static func removeOwned(_ ownership: Ownership, directory: URL, logs: URL, run: XcodeCommandRunner) throws -> [String] {
        let listing = try execute(["list", "devices", "-j"], logs: logs, timeout: 30, run: run)
        guard listing.exitCode == 0, !listing.timedOut, let data = listing.output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]] else {
            throw MutationEngineError.invalidProject("Cannot verify simulator ownership before cleanup: \(listing.outputFile.path)")
        }
        var failures: [String] = []
        for owned in ownership.devices {
            guard owned.name.hasPrefix("mutest-\(ownership.runID)-worker-") else { continue }
            // Recover by exact owned name if a previous process stopped after create but before saving its ID.
            for device in devices.values.flatMap({ $0 }) where device["name"] as? String == owned.name {
                guard let id = device["udid"] as? String, owned.id == nil || owned.id == id else { continue }
                _ = try execute(["shutdown", id], logs: logs, timeout: 15, run: run)
                let result = try execute(["delete", id], logs: logs, timeout: 15, run: run)
                if result.exitCode != 0 || result.timedOut { failures.append("Could not delete owned simulator \(id); see \(result.outputFile.path).") }
            }
        }
        if failures.isEmpty { try FileManager.default.removeItem(at: directory) }
        return failures
    }

    private static func recoverStalePools(parent: URL, logs: URL, run: XcodeCommandRunner) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("ownership.json")),
                  let ownership = try? JSONDecoder().decode(Ownership.self, from: data), directory.lastPathComponent == ownership.runID else { continue }
            let fd = open(directory.appendingPathComponent("owner.lock").path, O_RDWR | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { _ = close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { _ = flock(fd, LOCK_UN) }
            let failures = try removeOwned(ownership, directory: directory, logs: logs, run: run)
            if !failures.isEmpty { throw MutationEngineError.invalidProject(failures.joined(separator: "\n")) }
        }
    }
}
