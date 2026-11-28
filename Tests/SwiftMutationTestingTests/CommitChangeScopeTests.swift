import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Commit-based source and test selection")
struct CommitChangeScopeTests {
    @Test("changed files select all test targets in affected packages only")
    func affectedPackageTargets() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Example", targets: [
            .target(name: "Feature"),
            .testTarget(name: "FeatureTests", dependencies: ["Feature"]),
            .testTarget(name: "IntegrationTests", dependencies: ["Feature"])
        ])
        """
        try write(manifest, to: "Modules/Feature/Package.swift", in: repository)
        try write(manifest.replacingOccurrences(of: "Feature", with: "Other").replacingOccurrences(of: "IntegrationTests", with: "OtherIntegrationTests"), to: "Modules/Other/Package.swift", in: repository)
        try write("let value = 1", to: "Modules/Feature/Sources/Feature/A.swift", in: repository)
        try write("let value = 1", to: "Modules/Other/Sources/Other/B.swift", in: repository)
        let base = try commit(repository, message: "base")
        try write("let value = 2", to: "Modules/Feature/Sources/Feature/A.swift", in: repository)
        let head = try commit(repository, message: "change feature")
        let selection = try CommitChangeScopeResolver.resolve(projectRoot: repository, sourceCommit: head, sourceBase: base, testFileSuffixes: [])
        let packages = try CommitChangeScopeResolver.affectedPackages(projectRoot: repository, sourceFiles: selection.changedSourceFiles)
        #expect(packages == ["Modules/Feature"])
        #expect(try CommitChangeScopeResolver.packageTestTargets(projectRoot: repository, packages: packages) == ["FeatureTests", "IntegrationTests"])
        let both = try CommitChangeScopeResolver.affectedPackages(projectRoot: repository, sourceFiles: ["Modules/Feature/Sources/Feature/A.swift", "Modules/Other/Sources/Other/B.swift"])
        #expect(both == ["Modules/Feature", "Modules/Other"])
        #expect(try CommitChangeScopeResolver.packageTestTargets(projectRoot: repository, packages: both) == ["FeatureTests", "IntegrationTests", "OtherIntegrationTests", "OtherTests"])
        #expect(throws: CommitScopeError.self) {
            try CommitChangeScopeResolver.affectedPackages(projectRoot: repository, sourceFiles: ["App/Screen.swift"])
        }
    }
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

    @Test("comment and blank-line edits keep Swift sources and tests selected")
    func nonExecutableEditsStillSelectFiles() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        try write("let value = true\n", to: "Sources/Foo.swift", in: repository)
        try write("import Testing\n", to: "Tests/UnrelatedTests.swift", in: repository)
        let base = try commit(repository, message: "base")
        try write("// A comment\nlet value = true\n\n", to: "Sources/Foo.swift", in: repository)
        try write("import Testing\n\n", to: "Tests/UnrelatedTests.swift", in: repository)
        let head = try commit(repository, message: "comments and whitespace")

        let selection = try CommitChangeScopeResolver.resolve(projectRoot: repository, sourceCommit: head, sourceBase: base, testFileSuffixes: [])
        #expect(selection.changedSourceFiles == ["Sources/Foo.swift"])
        #expect(selection.testFiles(for: "changed-and-matching") == ["Tests/UnrelatedTests.swift"])
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

    @Test("provides a skip reason when the requested test scope selects no files")
    func noSelectedTestsHasSkipReason() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        try write("let total = 1\n", to: "Sources/Feature/Foo.swift", in: repository)
        try write("import Testing\n", to: "Tests/FeatureTests/UnrelatedTests.swift", in: repository)
        let base = try commit(repository, message: "base")
        try write("let total = 2\n", to: "Sources/Feature/Foo.swift", in: repository)
        let head = try commit(repository, message: "change source without matching tests")

        let selection = try CommitChangeScopeResolver.resolve(
            projectRoot: repository,
            sourceCommit: head,
            sourceBase: base,
            testFileSuffixes: []
        )

        #expect(selection.testFiles(for: "changed-and-matching").isEmpty)
        #expect(selection.noTestFilesSkipReason(for: "changed-and-matching", hasExplicitTestSelection: false)
            == "Mutation testing skipped: no test files were selected for test scope 'changed-and-matching'.")
        #expect(selection.noTestFilesSkipReason(for: "changed-and-matching", hasExplicitTestSelection: true) == nil)
        #expect(selection.noTestFilesSkipReason(for: "all", hasExplicitTestSelection: false) == nil)
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
