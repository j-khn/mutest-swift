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
    /// nil automatically narrows builds when the selected test scope names targets.
    public var narrowTestBuild: Bool?
    public var testPlan: String?
    public var buildTimingSummary: Bool
    public var codeCoverage: Bool?

    public init(jobs: Int? = nil, cacheDirectory: URL? = nil, narrowTestBuild: Bool? = nil,
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
        if kind == .swiftPackage && (jobs != nil || cacheDirectory != nil || narrowTestBuild != nil || testPlan != nil || buildTimingSummary || codeCoverage != nil) {
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

    func prepare(_ staged: ProjectSandbox) throws -> ProjectSandbox {
        guard lockDescriptor != nil else { return staged }
        do {
            try syncDirectory(from: staged.container, to: sourceDirectory)
        } catch ProcessRunnerError.cancelled {
            throw ProcessRunnerError.cancelled
        } catch {
            throw MutationEngineError.invalidProject("Could not synchronize the compiled Xcode build cache at \(sourceDirectory.path): \(error)")
        }
        func relocate(_ url: URL) -> URL {
            let relative = PackageDependencyResolver.relativePath(url, to: staged.container)
            return relative.isEmpty ? sourceDirectory : sourceDirectory.appendingPathComponent(relative)
        }
        return ProjectSandbox(container: sourceDirectory, root: relocate(staged.root), localPackages: staged.localPackages.map(relocate))
    }

    private func syncDirectory(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let inputs = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys))
        let existing = try files.contentsOfDirectory(at: destination, includingPropertiesForKeys: Array(keys))
        let names = Set(inputs.map(\.lastPathComponent))
        var previousFiles: [String: URL] = [:]
        for file in existing {
            if names.contains(file.lastPathComponent) { previousFiles[file.lastPathComponent] = file }
            else { try files.removeItem(at: file) }
        }
        for input in inputs {
            if ProcessRunner.cancellationRequested { throw ProcessRunnerError.cancelled }
            let previous = previousFiles[input.lastPathComponent]
            let path = destination.appendingPathComponent(input.lastPathComponent)
            let kind = try input.resourceValues(forKeys: keys)
            let oldKind = try previous?.resourceValues(forKeys: keys)
            if kind.isSymbolicLink == true {
                let link = try files.destinationOfSymbolicLink(atPath: input.path)
                if oldKind?.isSymbolicLink == true, try files.destinationOfSymbolicLink(atPath: path.path) == link { continue }
                if let previous { try files.removeItem(at: previous) }
                try files.createSymbolicLink(atPath: path.path, withDestinationPath: link)
            } else if kind.isDirectory == true {
                if let previous, oldKind?.isDirectory != true || oldKind?.isSymbolicLink == true {
                    try files.removeItem(at: previous)
                }
                try syncDirectory(from: input, to: path)
            } else if kind.isRegularFile == true {
                if oldKind?.isRegularFile == true, oldKind?.isSymbolicLink != true,
                   files.contentsEqual(atPath: input.path, andPath: path.path) {
                    // Leave unchanged file times alone, including when an ordinary
                    // checkout rewrites the whole source tree between CI runs.
                    let required = try files.attributesOfItem(atPath: input.path)[.posixPermissions] as? NSNumber
                    let actual = try files.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
                    if let required, required != actual {
                        try files.setAttributes([.posixPermissions: required], ofItemAtPath: path.path)
                    }
                    continue
                }
                if let previous { try files.removeItem(at: previous) }
                try files.copyItem(at: input, to: path)
                // touch only replaced files, even when the checkout supplies the
                // same mtime and size for different versions of a file.
                try files.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
            } else {
                throw MutationEngineError.invalidProject("Unsupported file in Xcode cache inputs: \(input.path)")
            }
        }
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
