import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Commit-based source and test selection")
struct CommitChangeScopeTests {
    @Test("selects changed source and test files, and finds matching test filenames")
    func changedAndMatchingFiles() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        try write("let total = 1\n", to: "Sources/Feature/Foo.swift", in: repository)
        try write("import Testing\n", to: "Tests/FeatureTests/FooTests.swift", in: repository)
        try write("import Testing\n", to: "Tests/FeatureTests/BarTests.swift", in: repository)
        try write("// manifest\n", to: "Package.swift", in: repository)
        let base = try commit(repository, message: "base")

        try write("let total = 2\n", to: "Sources/Feature/Foo.swift", in: repository)
        try write("import Testing\n// changed\n", to: "Tests/FeatureTests/BarTests.swift", in: repository)
        try write("// changed manifest\n", to: "Package.swift", in: repository)
        let head = try commit(repository, message: "change source and tests")

        let selection = try CommitChangeScopeResolver.resolve(
            projectRoot: repository,
            sourceCommit: head,
            sourceBase: base,
            testFileSuffixes: []
        )

        #expect(selection.changedSourceFiles == ["Sources/Feature/Foo.swift"])
        #expect(selection.changedTestFiles == ["Tests/FeatureTests/BarTests.swift"])
        #expect(selection.matchingTestFiles == ["Tests/FeatureTests/FooTests.swift"])
        #expect(selection.testFiles(for: "changed-and-matching") == [
            "Tests/FeatureTests/BarTests.swift",
            "Tests/FeatureTests/FooTests.swift"
        ])
        #expect(selection.testPackageRoots == ["."])
    }

    @Test("supports a caller-supplied matching test suffix")
    func customTestSuffix() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        try write("let total = 1\n", to: "Sources/Feature/Foo.swift", in: repository)
        try write("import Testing\n", to: "Tests/FeatureTests/FooSpec.swift", in: repository)
        let base = try commit(repository, message: "base")

        try write("let total = 2\n", to: "Sources/Feature/Foo.swift", in: repository)
        let head = try commit(repository, message: "change source")

        let selection = try CommitChangeScopeResolver.resolve(
            projectRoot: repository,
            sourceCommit: head,
            sourceBase: base,
            testFileSuffixes: ["Spec.swift"]
        )

        #expect(selection.matchingTestFiles == ["Tests/FeatureTests/FooSpec.swift"])
    }

    @Test("compares a new GitHub branch push with the empty tree")
    func zeroBaseUsesEmptyTree() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("let total = 1\n", to: "Sources/Feature/Foo.swift", in: repository)
        try write("import Testing\n", to: "Tests/FeatureTests/FooTests.swift", in: repository)
        let head = try commit(repository, message: "first branch commit")

        let selection = try CommitChangeScopeResolver.resolve(
            projectRoot: repository,
            sourceCommit: head,
            sourceBase: String(repeating: "0", count: head.count),
            testFileSuffixes: []
        )

        #expect(selection.changedSourceFiles == ["Sources/Feature/Foo.swift"])
        #expect(selection.changedTestFiles == ["Tests/FeatureTests/FooTests.swift"])
    }

    @Test("rejects a requested commit that is not checked out")
    func requiresCheckedOutCommit() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("let total = 1\n", to: "Sources/Feature/Foo.swift", in: repository)
        let head = try commit(repository, message: "head")

        #expect(throws: CommitScopeError.self) {
            try CommitChangeScopeResolver.resolve(
                projectRoot: repository,
                sourceCommit: String(repeating: "0", count: head.count),
                sourceBase: nil,
                testFileSuffixes: []
            )
        }
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], at: root)
        try runGit(["config", "user.email", "mutest-tests@example.invalid"], at: root)
        try runGit(["config", "user.name", "mutest tests"], at: root)
        return root
    }

    @discardableResult
    private func commit(_ root: URL, message: String) throws -> String {
        try runGit(["add", "-A"], at: root)
        try runGit(["commit", "-q", "-m", message], at: root)
        return try runGit(["rev-parse", "HEAD"], at: root)
    }

    private func write(_ text: String, to relativePath: String, in root: URL) throws {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try? output.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestError.gitCommandFailed(String(decoding: data, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum TestError: Error {
    case gitCommandFailed(String)
}
