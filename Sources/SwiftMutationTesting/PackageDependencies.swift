import Foundation

struct PackageDependencyGraph: Sendable {
    var localPackages: [URL]
    var commonRoot: URL
}

struct ProjectSandbox: Sendable {
    var container: URL
    var root: URL
    var localPackages: [URL]
}

enum PackageDependencyResolver {
    static func discover(projectURL: URL, projectRoot: URL, kind: ProjectKind, logs: URL,
                         timeout: TimeInterval) throws -> PackageDependencyGraph {
        var queue: [URL]
        switch kind {
        case .swiftPackage: queue = [projectRoot]
        case .xcodeProject: queue = try localPackages(in: projectURL)
        case .xcodeWorkspace: queue = try localPackages(inWorkspace: projectURL)
        }
        var visited = Set<String>()
        var packages: [URL] = []
        let runner = ProcessRunner()
        var index = 0
        while !queue.isEmpty {
            let package = queue.removeFirst().standardizedFileURL
            guard visited.insert(package.path).inserted else { continue }
            let manifest = package.appendingPathComponent("Package.swift")
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                throw MutationEngineError.invalidProject("Local package dependency has no Package.swift: \(package.path)")
            }
            packages.append(package)
            index += 1
            let dumpLog = logs.appendingPathComponent("package-manifest-\(index).json")
            let dump = try runner.run(.init(executable: "/usr/bin/swift", arguments: ["package", "dump-package"],
                workingDirectory: package, timeout: timeout, outputFile: dumpLog))
            guard !dump.timedOut, dump.exitCode == 0 else {
                throw MutationEngineError.invalidProject("Could not read package dependencies from \(manifest.path). See \(dumpLog.path)")
            }
            for path in try localDependencyPaths(in: dump.output, manifest: manifest) {
                let dependency = URL(fileURLWithPath: path, relativeTo: package).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dependency.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MutationEngineError.invalidProject("Local package dependency '\(path)' declared in \(manifest.path) does not exist at \(dependency.path).")
                }
                guard FileManager.default.fileExists(atPath: dependency.appendingPathComponent("Package.swift").path) else {
                    throw MutationEngineError.invalidProject("Local dependency '\(path)' declared in \(manifest.path) is not a Swift package (Package.swift was not found).")
                }
                queue.append(dependency)
            }
            try? FileManager.default.removeItem(at: dumpLog)
        }
        let unique = Array(Dictionary(grouping: packages, by: \.path).values.compactMap(\.first)).sorted { $0.path < $1.path }
        let commonRoot = commonAncestor(of: [projectRoot] + unique)
        let localDependencies = unique.filter { $0.standardizedFileURL != projectRoot.standardizedFileURL }
        let names = localDependencies.map(\.lastPathComponent).joined(separator: ", ")
        mutationLog("Package manifests inspected: \(unique.count); local dependencies: \(localDependencies.count)\(names.isEmpty ? "" : " (\(names))"). Git requirements resolve through SwiftPM or Xcode.")
        return .init(localPackages: unique, commonRoot: commonRoot)
    }

    private static func localPackages(in project: URL) throws -> [URL] {
        let pbxproj = project.appendingPathComponent("project.pbxproj")
        guard let contents = try? String(contentsOf: pbxproj, encoding: .utf8) else {
            throw MutationEngineError.invalidProject("Could not read Xcode project file at \(pbxproj.path).")
        }
        return try packageReferences(in: contents, basedAt: project.deletingLastPathComponent(), manifest: pbxproj)
    }

    private static func localPackages(inWorkspace workspace: URL) throws -> [URL] {
        let data = workspace.appendingPathComponent("contents.xcworkspacedata")
        guard let contents = try? String(contentsOf: data, encoding: .utf8), let xml = contents.data(using: .utf8) else {
            throw MutationEngineError.invalidProject("Could not read Xcode workspace file at \(data.path).")
        }
        let delegate = WorkspaceFileReferenceParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else { throw MutationEngineError.invalidProject("Could not read Xcode workspace references in \(data.path).") }
        let workspaceBase = workspace.deletingLastPathComponent()
        var packages: [URL] = []
        for reference in delegate.references {
            guard let colon = reference.firstIndex(of: ":") else { continue }
            let kind = String(reference[..<colon])
            let path = String(reference[reference.index(after: colon)...])
            let resolved: URL
            switch kind {
            case "absolute": resolved = URL(fileURLWithPath: path).standardizedFileURL
            case "group": resolved = URL(fileURLWithPath: path, relativeTo: workspaceBase).standardizedFileURL
            case "container": resolved = URL(fileURLWithPath: path, relativeTo: workspaceBase).standardizedFileURL
            default: continue
            }
            if resolved.pathExtension == "xcodeproj" { packages += try localPackages(in: resolved) }
            else if FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Package.swift").path) { packages.append(resolved) }
        }
        return packages
    }

    private static func packageReferences(in contents: String, basedAt base: URL, manifest: URL) throws -> [URL] {
        var paths: [String] = []
        var block = ""
        var depth = 0
        var inObject = false
        var inString = false
        var escaped = false
        var inBlockComment = false
        for line in contents.components(separatedBy: .newlines) {
            if !inObject && line.range(of: #"^\s*[A-Fa-f0-9]{12,32}(?:\s*/\*.*?\*/)?\s*=\s*\{"#, options: .regularExpression) != nil {
                inObject = true; block = ""; depth = 0; inString = false; escaped = false; inBlockComment = false
            }
            guard inObject else { continue }
            block += line + "\n"
            let chars = Array(line)
            var index = 0
            while index < chars.count {
                let char = chars[index]
                let next = index + 1 < chars.count ? chars[index + 1] : "\0"
                if inBlockComment {
                    if char == "*" && next == "/" { inBlockComment = false; index += 2; continue }
                    index += 1; continue
                }
                if inString {
                    if escaped { escaped = false }
                    else if char == "\\" { escaped = true }
                    else if char == "\"" { inString = false }
                    index += 1; continue
                }
                if char == "/" && next == "*" { inBlockComment = true; index += 2; continue }
                if char == "\"" { inString = true; index += 1; continue }
                if char == "{" { depth += 1 }
                if char == "}" { depth -= 1 }
                index += 1
            }
            if depth == 0 {
                inObject = false
                guard block.contains("isa = XCLocalSwiftPackageReference;") else { continue }
                guard let path = fieldValue("relativePath", in: block) else {
                    throw MutationEngineError.invalidProject("Xcode local package reference in \(manifest.path) has no relativePath.")
                }
                paths.append(path)
            }
        }
        return try paths.map { path in
            let resolved = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Package.swift").path) else {
                throw MutationEngineError.invalidProject("Xcode local package reference '\(path)' in \(manifest.path) has no Package.swift at \(resolved.path).")
            }
            return resolved
        }
    }

    private static func fieldValue(_ field: String, in block: String) -> String? {
        let quoted = #"\b\#(field)\s*=\s*"((?:\\.|[^"])*)"\s*;"#
        if let range = block.range(of: quoted, options: .regularExpression) {
            let value = String(block[range])
            guard let first = value.firstIndex(of: "\""), let last = value[value.index(after: first)...].firstIndex(of: "\"") else { return nil }
            return String(value[value.index(after: first)..<last]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        let unquoted = #"\b\#(field)\s*=\s*([^;]+)\s*;"#
        guard let range = block.range(of: unquoted, options: .regularExpression) else { return nil }
        return block[range].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ;\t\n\r")) }
    }

    private static func localDependencyPaths(in json: String, manifest: URL) throws -> [String] {
        guard let data = json.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [[String: Any]] else {
            throw MutationEngineError.invalidProject("SwiftPM returned an unreadable dependency graph for \(manifest.path).")
        }
        var result: [String] = []
        for dependency in dependencies {
            if let entries = dependency["fileSystem"] as? [[String: Any]] { result += entries.compactMap { $0["path"] as? String } }
            else if let entry = dependency["fileSystem"] as? [String: Any], let path = entry["path"] as? String { result.append(path) }
        }
        return result
    }

    private static func commonAncestor(of urls: [URL]) -> URL {
        let paths = urls.map { $0.standardizedFileURL.pathComponents }
        guard var prefix = paths.first else { return URL(fileURLWithPath: "/", isDirectory: true) }
        for path in paths.dropFirst() {
            var count = 0
            while count < min(prefix.count, path.count), prefix[count] == path[count] { count += 1 }
            prefix = Array(prefix.prefix(count))
        }
        let path = prefix.first == "/" ? "/" + prefix.dropFirst().joined(separator: "/") : prefix.joined(separator: "/")
        return URL(fileURLWithPath: path.isEmpty ? "/" : path, isDirectory: true).standardizedFileURL
    }

    static func relativePath(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        if path == rootPath { return "" }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private final class WorkspaceFileReferenceParser: NSObject, XMLParserDelegate {
    var references: [String] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "FileRef", let location = attributeDict["location"] { references.append(location) }
    }
}
