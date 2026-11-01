import Foundation

/// Keep build products and downloaded packages outside the sources inspected by
/// the project's build plugins. Each campaign owns and removes its workspace.
struct XcodeBuildWorkspace: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutest-xcode-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var derivedData: URL { directory.appendingPathComponent("DerivedData", isDirectory: true) }

    func isolatedDerivedData(worker: Int) -> URL {
        directory.appendingPathComponent("isolated-worker-\(worker)/DerivedData", isDirectory: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
