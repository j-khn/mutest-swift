import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CommandSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var timeout: TimeInterval
    public var outputFile: URL

    public init(executable: String, arguments: [String], workingDirectory: URL, environment: [String: String] = [:], timeout: TimeInterval, outputFile: URL) {
        self.executable = executable; self.arguments = arguments; self.workingDirectory = workingDirectory
        self.environment = environment; self.timeout = timeout; self.outputFile = outputFile
    }
}

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var elapsed: TimeInterval
    public var output: String
    public var outputFile: URL
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case spawnFailed(Int32, String)
    case ioFailed(String)
    case cancelled
    public var description: String {
        switch self {
        case .spawnFailed(let code, let executable): return "Could not launch \(executable) (posix_spawn error \(code))."
        case .ioFailed(let message): return "Process setup failed: \(message)"
        case .cancelled: return "Process execution was cancelled."
        }
    }
}

private final class ProcessGroupRegistry: @unchecked Sendable {
    static let shared = ProcessGroupRegistry()
    private let lock = NSLock()
    private var groups: Set<pid_t> = []
    private var cancelled = false
    private var signalSources: [DispatchSourceSignal] = []

    func installSignalHandlers() {
        lock.lock(); defer { lock.unlock() }
        guard signalSources.isEmpty else { return }
        for signalNumber in [SIGINT, SIGTERM] {
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.cancelAll() }
            source.resume()
            signalSources.append(source)
        }
    }

    func register(_ pid: pid_t) {
        lock.lock()
        let alreadyCancelled = cancelled
        if !alreadyCancelled { groups.insert(pid) }
        lock.unlock()
        if alreadyCancelled { _ = kill(-pid, SIGTERM) }
    }

    func unregister(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        groups.remove(pid)
    }

    func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func cancelAll() {
        lock.lock()
        cancelled = true
        let activeGroups = groups
        lock.unlock()
        for pid in activeGroups { _ = kill(-pid, SIGTERM) }
    }
}

/// Runs commands in their own process group and writes combined stdout/stderr to a log file.
/// Timed-out commands receive SIGTERM, then SIGKILL after the configured grace period.
public struct ProcessRunner: Sendable {
    public var terminationGrace: TimeInterval
    private let cancellationCheck: @Sendable () -> Bool
    public init(terminationGrace: TimeInterval = 5) {
        self.terminationGrace = terminationGrace
        self.cancellationCheck = { ProcessGroupRegistry.shared.isCancelled() }
    }

    public init(terminationGrace: TimeInterval = 5, cancellationCheck: @escaping @Sendable () -> Bool) {
        self.terminationGrace = terminationGrace
        self.cancellationCheck = cancellationCheck
    }

    /// Installs process-wide SIGINT/SIGTERM handlers for CLI use. Active child process groups
    /// receive graceful termination and are force-killed after the configured grace period.
    public static func installCancellationHandlers() {
        ProcessGroupRegistry.shared.installSignalHandlers()
    }

    public static var cancellationRequested: Bool {
        ProcessGroupRegistry.shared.isCancelled()
    }

    public func run(_ command: CommandSpec) throws -> CommandResult {
        guard !isCancellationRequested else { throw ProcessRunnerError.cancelled }
        try FileManager.default.createDirectory(at: command.outputFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let outputFD = open(command.outputFile.path, O_CREAT | O_WRONLY | O_TRUNC, mode_t(0o644))
        guard outputFD >= 0 else { throw ProcessRunnerError.ioFailed("cannot open \(command.outputFile.path)") }
        defer { _ = close(outputFD) }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ProcessRunnerError.ioFailed("cannot initialize file actions") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_adddup2(&actions, outputFD, STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, outputFD, STDERR_FILENO)
        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        #if canImport(Darwin)
        let chdirResult = posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory.path)
        #else
        let chdirResult = posix_spawn_file_actions_addchdir_np(&actions, command.workingDirectory.path)
        #endif
        guard chdirResult == 0 else { throw ProcessRunnerError.ioFailed("cannot set working directory") }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else { throw ProcessRunnerError.ioFailed("cannot initialize spawn attributes") }
        defer { posix_spawnattr_destroy(&attributes) }
        _ = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        _ = posix_spawnattr_setpgroup(&attributes, 0)

        let args = [command.executable] + command.arguments
        let argumentPointers = args.compactMap { strdup($0) }
        defer { argumentPointers.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = argumentPointers.map { Optional($0) } + [nil]
        var inherited = ProcessInfo.processInfo.environment
        command.environment.forEach { inherited[$0.key] = $0.value }
        let environmentPointers = inherited.keys.sorted().compactMap { key -> UnsafeMutablePointer<CChar>? in
            guard let value = inherited[key] else { return nil }
            return strdup("\(key)=\(value)")
        }
        defer { environmentPointers.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentPointers.map { Optional($0) } + [nil]
        var pid = pid_t(0)
        let started = Date()
        let spawnStatus = command.executable.withCString { executable in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(&pid, executable, &actions, &attributes, argvBuffer.baseAddress!, envBuffer.baseAddress!)
                }
            }
        }
        guard spawnStatus == 0 else { throw ProcessRunnerError.spawnFailed(spawnStatus, command.executable) }
        ProcessGroupRegistry.shared.register(pid)
        defer { ProcessGroupRegistry.shared.unregister(pid) }

        var status: Int32 = 0
        var timedOut = false
        var exitedNormally = false
        while true {
            let waitResult = waitpid(pid, &status, WNOHANG)
            if waitResult == pid { exitedNormally = true; break }
            if waitResult < 0 && errno != EINTR { break }
            if Date().timeIntervalSince(started) >= command.timeout || isCancellationRequested {
                timedOut = !isCancellationRequested
                _ = kill(-pid, SIGTERM)
                let graceDeadline = Date().addingTimeInterval(terminationGrace)
                var parentReaped = false
                while Date() < graceDeadline {
                    if !parentReaped {
                        let graceResult = waitpid(pid, &status, WNOHANG)
                        if graceResult == pid { parentReaped = true }
                    }
                    if !processGroupExists(pid) { break }
                    usleep(50_000)
                }
                if processGroupExists(pid) { _ = kill(-pid, SIGKILL) }
                if !parentReaped { _ = waitpid(pid, &status, 0) }
                break
            }
            usleep(50_000)
        }
        if exitedNormally { terminateRemainingProcessGroup(pid) }
        if isCancellationRequested {
            terminateRemainingProcessGroup(pid)
            throw ProcessRunnerError.cancelled
        }
        let exitCode: Int32
        if (status & 0x7f) == 0 { exitCode = (status >> 8) & 0xff }
        else { exitCode = 128 + (status & 0x7f) }
        let data = (try? Data(contentsOf: command.outputFile)) ?? Data()
        return CommandResult(exitCode: exitCode, timedOut: timedOut, elapsed: Date().timeIntervalSince(started), output: String(decoding: data, as: UTF8.self), outputFile: command.outputFile)
    }

    private func terminateRemainingProcessGroup(_ pid: pid_t) {
        guard processGroupExists(pid) else { return }
        _ = kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(terminationGrace)
        while Date() < deadline && processGroupExists(pid) { usleep(50_000) }
        if processGroupExists(pid) { _ = kill(-pid, SIGKILL) }
    }

    private var isCancellationRequested: Bool {
        ProcessGroupRegistry.shared.isCancelled() || cancellationCheck()
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        if kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
