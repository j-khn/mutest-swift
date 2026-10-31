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

    @Test("stops a mutant run after an activated test failure")
    func stopsAfterActivatedFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("early-stop.log")
        let activation = directory.appendingPathComponent("activation.txt")
        let script = #"printf '%s\n' "$MUTANT_ID" > "$ACTIVATION_FILE"; printf 'SWIFT_MUTATION_ACTIVATED:%s\n' "$MUTANT_ID"; printf '✘ Test selectedCase() failed\n'; sleep 10 & wait"#
        let command = CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: directory,
            environment: ["MUTANT_ID": "mutant-1", "ACTIVATION_FILE": activation.path],
            timeout: 8,
            outputFile: output,
            stopOnActivatedTestFailure: true,
            activationID: "mutant-1",
            activationFile: activation
        )

        let result = try ProcessRunner(terminationGrace: 0.2).run(command)
        #expect(result.stoppedEarly)
        #expect(!result.timedOut)
        #expect(result.output.contains("selectedCase"))
        #expect(result.elapsed < 3)
    }

    @Test("does not stop on test output until this mutant is activated")
    func requiresActivationBeforeEarlyStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("unactivated.log")
        let activation = directory.appendingPathComponent("activation.txt")
        let script = #"printf '✘ Test selectedCase() failed\n'; sleep 0.4"#
        let command = CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: directory,
            timeout: 3,
            outputFile: output,
            stopOnActivatedTestFailure: true,
            activationID: "mutant-1",
            activationFile: activation
        )

        let result = try ProcessRunner().run(command)
        #expect(!result.stoppedEarly)
        #expect(result.exitCode == 0)
        #expect(result.elapsed >= 0.3)
    }

    @Test("does not stop for a failure printed before activation")
    func failureMustFollowActivation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("failure-before-activation.log")
        let activation = directory.appendingPathComponent("activation.txt")
        let script = #"printf '✘ Test unrelatedCase() failed\n'; sleep 0.1; printf '%s\n' "$MUTANT_ID" > "$ACTIVATION_FILE"; printf 'SWIFT_MUTATION_ACTIVATED:%s\n' "$MUTANT_ID"; sleep 0.4"#
        let command = CommandSpec(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: directory,
            environment: ["MUTANT_ID": "mutant-1", "ACTIVATION_FILE": activation.path],
            timeout: 3,
            outputFile: output,
            stopOnActivatedTestFailure: true,
            activationID: "mutant-1",
            activationFile: activation
        )

        let result = try ProcessRunner().run(command)
        #expect(!result.stoppedEarly)
        #expect(result.exitCode == 0)
        #expect(result.elapsed >= 0.4)
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
