import Foundation

public struct CommitChangeSelection {
    public var headCommit: String
    public var baseCommit: String
    public var changedSourceFiles: [String]
    public var changedTestFiles: [String]
    public var matchingTestFiles: [String]
    public var testPackageRoots: [String]

    public func testFiles(for scope: String) -> [String] {
        switch scope {
        case "changed": return changedTestFiles
        case "matching": return matchingTestFiles
        case "changed-and-matching": return Array(Set(changedTestFiles + matchingTestFiles)).sorted()
        default: return []
        }
    }
}

public enum CommitScopeError: Error, CustomStringConvertible {
    case usage(String)

    public var description: String {
        if case .usage(let message) = self { return message }
        return "Invalid commit scope."
    }
}

public enum CommitChangeScopeResolver {
    public static func resolve(projectRoot: URL, sourceCommit: String, sourceBase: String?, testFileSuffixes: [String]) throws -> CommitChangeSelection {
        let projectRoot = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let repositoryRoot = URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], at: projectRoot), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isWithin(projectRoot, root: repositoryRoot) else {
            throw CommitScopeError.usage("The Xcode project or package must be inside the Git repository for commit-based selection.")
        }

        let headCommit = try resolveCommit(sourceCommit, at: repositoryRoot, label: "source commit")
        let checkedOutCommit = try resolveCommit("HEAD", at: repositoryRoot, label: "checked-out commit")
        guard headCommit == checkedOutCommit else {
            throw CommitScopeError.usage("--source-commit must match the checked-out commit. Checked out \(checkedOutCommit), requested \(headCommit).")
        }

        let baseCommit: String
        if let sourceBase, !sourceBase.isEmpty {
            baseCommit = isAllZero(sourceBase)
                ? try emptyTree(at: repositoryRoot)
                : try resolveCommit(sourceBase, at: repositoryRoot, label: "source base")
        } else if let parent = try? git(["rev-parse", "--verify", "HEAD^"], at: repositoryRoot) {
            baseCommit = parent
        } else {
            baseCommit = try emptyTree(at: repositoryRoot)
        }

        let diffData = try gitData([
            "diff", "--name-only", "-z", "--find-renames", "--diff-filter=ACMR", baseCommit, headCommit, "--"
        ], at: repositoryRoot)
        let changedRepositoryPaths = decodePaths(diffData)
        let changedPaths = changedRepositoryPaths.compactMap {
            projectRelativePath($0, repositoryRoot: repositoryRoot, projectRoot: projectRoot)
        }.filter { isSwiftImplementationFile($0) }.sorted()

        let suffixes = Array(Set(testFileSuffixes.filter { !$0.isEmpty }.isEmpty ? ["Tests.swift"] : testFileSuffixes)).sorted()
        let changedTestFiles = changedPaths.filter { isTestFile($0, suffixes: suffixes) }
        let changedSourceFiles = changedPaths.filter { !isTestFile($0, suffixes: suffixes) }

        let trackedSwiftPaths = decodePaths(try gitData(["ls-files", "-z", "--", "*.swift"], at: repositoryRoot))
            .compactMap { projectRelativePath($0, repositoryRoot: repositoryRoot, projectRoot: projectRoot) }
        let trackedByName = Dictionary(grouping: trackedSwiftPaths, by: { URL(fileURLWithPath: $0).lastPathComponent })
        var matchingTestFiles = Set<String>()
        for source in changedSourceFiles {
            let stem = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
            for suffix in suffixes {
                let candidateName = stem + suffix
                for candidate in trackedByName[candidateName] ?? [] where isTestFile(candidate, suffixes: suffixes) {
                    matchingTestFiles.insert(candidate)
                }
            }
        }

        let selectedTestFiles = Array(Set(changedTestFiles).union(matchingTestFiles)).sorted()
        let packageRoots = Set(selectedTestFiles.compactMap {
            packageRoot(containing: $0, projectRoot: projectRoot)
        }).sorted()

        return CommitChangeSelection(
            headCommit: headCommit,
            baseCommit: baseCommit,
            changedSourceFiles: changedSourceFiles,
            changedTestFiles: changedTestFiles,
            matchingTestFiles: matchingTestFiles.sorted(),
            testPackageRoots: packageRoots
        )
    }

    private static func resolveCommit(_ value: String, at repositoryRoot: URL, label: String) throws -> String {
        do {
            return try git(["rev-parse", "--verify", "--end-of-options", "\(value)^{commit}"], at: repositoryRoot)
        } catch {
            throw CommitScopeError.usage("Could not resolve \(label) '\(value)' in the current checkout. Fetch that commit before running commit-based selection.")
        }
    }

    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let output = try gitData(arguments, at: directory)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitData(_ arguments: [String], at directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw CommitScopeError.usage("Could not start Git: \(error.localizedDescription)")
        }
        try? pipe.fileHandleForWriting.close()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommitScopeError.usage("Git command failed (\(process.terminationStatus)): \(detail)")
        }
        return output
    }

    private static func decodePaths(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func projectRelativePath(_ repositoryPath: String, repositoryRoot: URL, projectRoot: URL) -> String? {
        let absolute = repositoryRoot.appendingPathComponent(repositoryPath).standardizedFileURL
        guard isWithin(absolute, root: projectRoot), absolute.path != projectRoot.path else { return nil }
        return String(absolute.path.dropFirst(projectRoot.path.count + 1))
    }

    private static func packageRoot(containing relativeFile: String, projectRoot: URL) -> String? {
        var directory = projectRoot.appendingPathComponent(relativeFile).deletingLastPathComponent().standardizedFileURL
        while isWithin(directory, root: projectRoot) {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                if directory.path == projectRoot.path { return "." }
                return String(directory.path.dropFirst(projectRoot.path.count + 1))
            }
            guard directory.path != projectRoot.path else { break }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private static func isAllZero(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0 == "0" }
    }

    private static func emptyTree(at repositoryRoot: URL) throws -> String {
        try git(["hash-object", "-t", "tree", "/dev/null"], at: repositoryRoot)
    }

    private static func isTestFile(_ path: String, suffixes: [String]) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        if components.contains(where: { $0 == "test" || $0 == "tests" || $0.hasSuffix("tests") }) { return true }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return suffixes.contains(where: { filename.hasSuffix($0) })
            || filename.hasSuffix("Test.swift")
            || filename.hasSuffix("Tests.swift")
    }

    private static func isSwiftImplementationFile(_ path: String) -> Bool {
        guard path.hasSuffix(".swift") else { return false }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        guard filename != "Package.swift", !filename.hasPrefix("Package@swift-") else { return false }
        let ignoredDirectories: Set<String> = [".build", "DerivedData", ".swift-mutation-testing"]
        return !path.split(separator: "/").contains { ignoredDirectories.contains(String($0)) }
    }
}
