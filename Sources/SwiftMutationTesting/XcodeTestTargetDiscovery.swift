import Foundation

enum XcodeTestTargetDiscovery {
    static func testTargetBySourceFile(in project: URL) throws -> [String: [String]] {
        let pbxproj = project.appendingPathComponent("project.pbxproj")
        let contents = try String(contentsOf: pbxproj, encoding: .utf8)
        return try testTargetBySourceFile(in: contents, projectRoot: project.deletingLastPathComponent())
    }

    static func testTargetBySourceFile(in contents: String, projectRoot: URL) throws -> [String: [String]] {
        guard let data = contents.data(using: .utf8) else {
            throw MutationEngineError.invalidProject("Could not decode the Xcode project file.")
        }
        var format = PropertyListSerialization.PropertyListFormat.openStep
        guard let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]],
              let projectID = root["rootObject"] as? String,
              let mainGroupID = objects[projectID]?["mainGroup"] as? String else {
            throw MutationEngineError.invalidProject("The Xcode project file has no readable main group or targets.")
        }

        let rootURL = projectRoot.standardizedFileURL
        var fileReferences: [String: URL] = [:]
        var visitedGroups = Set<String>()

        func groupURL(_ object: [String: Any], parent: URL) -> URL {
            guard let path = object["path"] as? String, !path.isEmpty else { return parent }
            let sourceTree = object["sourceTree"] as? String ?? "<group>"
            return resolve(path: path, sourceTree: sourceTree, parent: parent, projectRoot: rootURL) ?? parent
        }

        func visitGroup(_ identifier: String, parent: URL) {
            guard visitedGroups.insert(identifier).inserted, let object = objects[identifier] else { return }
            let isa = object["isa"] as? String ?? ""
            let location = groupURL(object, parent: parent)
            if isa == "PBXFileReference", let path = object["path"] as? String {
                let sourceTree = object["sourceTree"] as? String ?? "<group>"
                if let url = resolve(path: path, sourceTree: sourceTree, parent: parent, projectRoot: rootURL) {
                    fileReferences[identifier] = url
                }
                return
            }
            guard isa == "PBXGroup" || isa == "PBXVariantGroup" || isa == "PBXFileSystemSynchronizedRootGroup" else { return }
            for child in object["children"] as? [String] ?? [] { visitGroup(child, parent: location) }
        }
        visitGroup(mainGroupID, parent: rootURL)

        var result: [String: [String]] = [:]
        for (targetID, target) in objects where target["isa"] as? String == "PBXNativeTarget" {
            guard let name = target["name"] as? String,
                  let productType = target["productType"] as? String,
                  productType.contains("unit-test") || productType.contains("ui-testing") else { continue }

            for phaseID in target["buildPhases"] as? [String] ?? [] {
                guard let phase = objects[phaseID], phase["isa"] as? String == "PBXSourcesBuildPhase" else { continue }
                for buildFileID in phase["files"] as? [String] ?? [] {
                    guard let fileID = objects[buildFileID]?["fileRef"] as? String,
                          let file = fileReferences[fileID], file.pathExtension == "swift" else { continue }
                    result[file.standardizedFileURL.path, default: []].append(name)
                }
            }

            for groupID in target["fileSystemSynchronizedGroups"] as? [String] ?? [] {
                guard let group = objects[groupID] else { continue }
                let directory = groupURL(group, parent: rootURL)
                let excluded = synchronizedMembershipExceptions(group: group, targetID: targetID, objects: objects)
                guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator {
                    let relative = PackageDependencyResolver.relativePath(file, to: directory)
                    if excluded.contains(relative) {
                        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                        continue
                    }
                    if file.pathExtension == "swift" { result[file.standardizedFileURL.path, default: []].append(name) }
                }
            }
        }
        for file in result.keys { result[file] = Array(Set(result[file] ?? [])).sorted() }
        return result
    }

    private static func synchronizedMembershipExceptions(group: [String: Any], targetID: String, objects: [String: [String: Any]]) -> Set<String> {
        let identifiers = group["exceptions"] as? [String] ?? []
        return Set(identifiers.flatMap { identifier -> [String] in
            guard let exception = objects[identifier],
                  exception["isa"] as? String == "PBXFileSystemSynchronizedBuildFileExceptionSet",
                  exception["target"] as? String == targetID else { return [] }
            return exception["membershipExceptions"] as? [String] ?? []
        })
    }

    private static func resolve(path: String, sourceTree: String, parent: URL, projectRoot: URL) -> URL? {
        switch sourceTree {
        case "<absolute>": return URL(fileURLWithPath: path).standardizedFileURL
        case "SOURCE_ROOT": return URL(fileURLWithPath: path, relativeTo: projectRoot).standardizedFileURL
        case "<group>", "": return URL(fileURLWithPath: path, relativeTo: parent).standardizedFileURL
        default: return nil
        }
    }
}
