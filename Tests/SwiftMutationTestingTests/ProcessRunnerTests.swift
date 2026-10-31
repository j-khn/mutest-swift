import Foundation
import Testing
@testable import SwiftMutationTesting

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@Suite("Subprocess lifecycle")
struct ProcessRunnerTests {
    @Test("captures output from an argument-array process")
    func capturesOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("echo.log")
        let result = try ProcessRunner().run(.init(executable: "/bin/echo", arguments: ["value with spaces"], workingDirectory: directory, timeout: 3, outputFile: output))
        #expect(result.exitCode == 0)
        #expect(result.output.contains("value with spaces"))
    }

    @Test("terminates timed-out commands and their process group")
    func timeout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("timeout.log")
        let runner = ProcessRunner(terminationGrace: 0.2)
        let result = try runner.run(.init(executable: "/bin/sh", arguments: ["-c", "sleep 10 & wait"], workingDirectory: directory, timeout: 0.1, outputFile: output))
        #expect(result.timedOut)
        #expect(result.elapsed < 3)
    }

    @Test("cancellation terminates a child process group before returning")
    func cancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("cancel.log")
        let cancellation = CancellationFlag()
        let runner = ProcessRunner(terminationGrace: 0.2, cancellationCheck: { cancellation.isCancelled })
        let task = Task.detached {
            try runner.run(.init(executable: "/bin/sh", arguments: ["-c", "sleep 10 & wait"], workingDirectory: directory, timeout: 20, outputFile: output))
        }
        try await Task.sleep(for: .milliseconds(150))
        cancellation.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected the child command to be cancelled.")
        } catch ProcessRunnerError.cancelled {
            #expect(true)
        }
    }
}
