import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct XcodeBuildOptions: Sendable {
    /// nil lets Xcode schedule its own builds.
    public var jobs: Int?
    public var cacheDirectory: URL?
    public var narrowTestBuild: Bool
    public var testPlan: String?
    public var buildTimingSummary: Bool
    public var codeCoverage: Bool?

    public init(jobs: Int? = 2, cacheDirectory: URL? = nil, narrowTestBuild: Bool = false,
                testPlan: String? = nil, buildTimingSummary: Bool = false, codeCoverage: Bool? = nil) {
        self.jobs = jobs
        self.cacheDirectory = cacheDirectory
        self.narrowTestBuild = narrowTestBuild
        self.testPlan = testPlan
        self.buildTimingSummary = buildTimingSummary
        self.codeCoverage = codeCoverage
    }

    public func validate(for kind: ProjectKind) throws {
        if let jobs, jobs < 1 { throw ContractError.invalidConfiguration("Xcode build jobs must be positive or auto.") }
        if let testPlan, testPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ContractError.invalidConfiguration("Xcode test plan must be a non-empty name.")
        }
        if kind == .swiftPackage && (jobs != 2 || cacheDirectory != nil || narrowTestBuild || testPlan != nil || buildTimingSummary || codeCoverage != nil) {
            throw ContractError.invalidConfiguration("Xcode build options require an Xcode project or workspace.")
        }
    }
}

/// The temporary case owns all of its files. A persistent case holds an
/// exclusive lease until cleanup and leaves a dirty marker if a run aborts.
final class XcodeBuildWorkspace: @unchecked Sendable {
    let directory: URL
    private let lockDescriptor: Int32?
    private var cleaned = false

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutest-xcode-build-\(UUID().uuidString)", isDirectory: true)
        lockDescriptor = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private init(directory: URL, lockDescriptor: Int32) {
        self.directory = directory
        self.lockDescriptor = lockDescriptor
    }

    var derivedData: URL { directory.appendingPathComponent("DerivedData", isDirectory: true) }
    private var sourceDirectory: URL { directory.appendingPathComponent("sources", isDirectory: true) }
    private var dirtyMarker: URL { directory.appendingPathComponent("in-progress") }

    static func open(cache: URL, key: String) throws -> XcodeBuildWorkspace {
        let files = FileManager.default
        let entry = cache.appendingPathComponent("mutest-xcode-v1-\(SHA256Digest.hash(key))", isDirectory: true)
        try files.createDirectory(at: entry, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard entry.standardizedFileURL.path == entry.resolvingSymlinksInPath().path else {
            throw MutationEngineError.invalidProject("The compiled build cache entry must be a real directory: \(entry.path)")
        }
        let lockFile = entry.appendingPathComponent("lease")
        let descriptor = lockFile.path.withCString { DarwinOrGlibcOpen($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            throw MutationEngineError.invalidProject("Could not open the compiled build cache lock: \(lockFile.path)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            _ = close(descriptor)
            guard failure == EWOULDBLOCK else {
                throw MutationEngineError.invalidProject("Could not lock the compiled build cache: \(lockFile.path) (errno \(failure))")
            }
            mutationLog("Compiled Xcode build cache is busy; using a temporary workspace for this run.")
            return try XcodeBuildWorkspace()
        }

        let workspace = XcodeBuildWorkspace(directory: entry, lockDescriptor: descriptor)
        if files.fileExists(atPath: workspace.dirtyMarker.path) {
            mutationLog("The last run left an incomplete compiled Xcode build cache; starting clean.")
            try workspace.removeIfPresent(workspace.sourceDirectory)
            try workspace.removeIfPresent(workspace.derivedData)
        }
        for path in [workspace.sourceDirectory, workspace.derivedData] {
            if (try? files.destinationOfSymbolicLink(atPath: path.path)) != nil {
                throw MutationEngineError.invalidProject("Compiled build cache directories cannot be symbolic links: \(path.path)")
            }
        }
        let warm = files.fileExists(atPath: workspace.derivedData.path)
        try Data().write(to: workspace.dirtyMarker, options: .atomic)
        mutationLog("Compiled Xcode build cache \(warm ? "available" : "empty"): \(entry.path)")
        return workspace
    }

    func prepare(_ staged: ProjectSandbox, logs: URL, timeout: TimeInterval) throws -> ProjectSandbox {
        guard lockDescriptor != nil else { return staged }
        let files = FileManager.default
        try files.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        // Compare content so same-sized edits are detected, and preserve times
        // for unchanged inputs. New writes get a fresh mtime for Xcode.
        let command = CommandSpec(executable: "/usr/bin/rsync",
            arguments: ["-rlpc", "--delete", staged.container.path + "/", sourceDirectory.path + "/"],
            workingDirectory: staged.container, timeout: timeout,
            outputFile: logs.appendingPathComponent("build-cache-sync.log"))
        let result = try ProcessRunner().run(command)
        guard !result.timedOut, result.exitCode == 0 else {
            throw MutationEngineError.invalidProject("Could not synchronize the compiled Xcode build cache. Log: \(result.outputFile.path)")
        }
        func relocate(_ url: URL) -> URL {
            let relative = PackageDependencyResolver.relativePath(url, to: staged.container)
            return relative.isEmpty ? sourceDirectory : sourceDirectory.appendingPathComponent(relative)
        }
        return ProjectSandbox(container: sourceDirectory, root: relocate(staged.root), localPackages: staged.localPackages.map(relocate))
    }

    func markComplete() throws {
        if lockDescriptor != nil { try FileManager.default.removeItem(at: dirtyMarker) }
    }

    private func removeIfPresent(_ path: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: path.path) || (try? files.destinationOfSymbolicLink(atPath: path.path)) != nil {
            try files.removeItem(at: path)
        }
    }

    func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        if let lockDescriptor { _ = close(lockDescriptor) }
        else { try? FileManager.default.removeItem(at: directory) }
    }

    deinit { cleanup() }
}

private func DarwinOrGlibcOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags, mode)
    #else
    Glibc.open(path, flags, mode)
    #endif
}
