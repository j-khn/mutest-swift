import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum TestExecutionCount {
    /// XCTest repeats nested suite totals; Swift Testing prints a separate framework total.
    static func parse(_ output: String) -> Int? {
        func largest(_ pattern: String) -> Int? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).compactMap {
                Range($0.range(at: 1), in: output).flatMap { Int(output[$0]) }
            }.max()
        }
        let legacy = largest(#"Executed\s+(\d+)\s+tests?"#)
        let modern = largest(#"Test run with\s+(\d+)\s+tests?"#)
        guard legacy != nil || modern != nil else { return nil }
        return (legacy ?? 0) + (modern ?? 0)
    }
}

enum XcodeFileCopy {
    static func clone(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(Darwin)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        if source.path.withCString({ src in destination.path.withCString { dst in copyfile(src, dst, nil, flags) } }) == 0 { return }
        try? FileManager.default.removeItem(at: destination)
        #endif
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// An immutable product snapshot. Each invocation writes its own manifest beside the copied
/// products, so __TESTROOT__ remains correct and activation variables cannot leak between workers.
struct XcodeTestArtifacts: Sendable {
    var products: URL
    var template: URL
    var hostBundleIDs: [String]

    static func snapshot(derivedData: URL, into directory: URL, testTarget: String? = nil) throws -> Self {
        let original = derivedData.appendingPathComponent("Build/Products")
        let selectedTarget = testTarget.flatMap { $0.isEmpty ? nil : $0 }
        let candidates = try FileManager.default.contentsOfDirectory(at: original, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        let matches: [URL]
        if let selectedTarget {
            matches = try candidates.filter { file in containsTarget(try read(file), name: selectedTarget) }
        } else {
            // A scheme's default test plan may contain several test bundles. Preserve the
            // whole manifest so xcodebuild runs every target in that plan.
            matches = candidates
        }
        let defaults = try matches.filter { (try read($0)["TestPlan"] as? [String: Any])?["IsDefault"] as? Bool == true }
        let selected = defaults.isEmpty ? matches : defaults
        guard selected.count == 1, let manifest = selected.first else {
            let details = try candidates.map { file in
                let targets = targetDictionaries(try read(file)).map { target in
                    let name = target["BlueprintName"] as? String ?? "<unnamed>"
                    let bundle = target["TestBundlePath"] as? String ?? "<no bundle path>"
                    return "\(name): \(bundle)"
                }.joined(separator: ", ")
                return "\(file.lastPathComponent) [\(targets.isEmpty ? "no test targets" : targets)]"
            }
            let found = candidates.isEmpty
                ? "No .xctestrun files were generated."
                : "Found \(candidates.count) candidate(s): \(details.joined(separator: "; "))."
            let expected = selectedTarget.map { "for test target '\($0)' (or its default test plan)" } ?? "for the selected scheme's test plan"
            let scopeHint = selectedTarget == nil ? " Pass --test-target to select one target if the scheme produces multiple manifests." : ""
            throw MutationEngineError.invalidProject("Expected one generated test manifest \(expected); found \(selected.count) matching manifest(s) in \(original.path). \(found)\(scopeHint)")
        }
        let products = directory.appendingPathComponent("Products")
        try XcodeFileCopy.clone(original, to: products)
        let relocated = relocate(try read(manifest), from: original.path, to: products.path) as! [String: Any]
        let template = products.appendingPathComponent("mutest-template.plist")
        try write(relocated, to: template)
        let hosts = targetDictionaries(relocated).compactMap { $0["TestHostBundleIdentifier"] as? String }
        return Self(products: products, template: template, hostBundleIDs: Array(Set(hosts)).sorted())
    }

    static func removeGeneratedManifests(derivedData: URL) throws {
        let products = derivedData.appendingPathComponent("Build/Products", isDirectory: true)
        guard FileManager.default.fileExists(atPath: products.path) else { return }
        let manifests = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        for manifest in manifests { try FileManager.default.removeItem(at: manifest) }
    }

    func invocationManifest(environment: [String: String]) throws -> URL {
        let data = try Self.read(template)
        let updated = Self.inject(data, environment: environment) as! [String: Any]
        let path = products.appendingPathComponent("mutest-\(UUID().uuidString).xctestrun")
        try Self.write(updated, to: path)
        return path
    }

    static func inject(_ value: Any, environment: [String: String]) -> Any {
        if var object = value as? [String: Any] {
            for (key, child) in object { object[key] = inject(child, environment: environment) }
            if object["TestBundlePath"] != nil {
                var variables = object["EnvironmentVariables"] as? [String: String] ?? [:]
                variables = variables.filter { !$0.key.hasPrefix("SWIFT_MUTATION_") && !$0.key.hasPrefix("TEST_RUNNER_SWIFT_MUTATION_") }
                variables.merge(environment) { _, new in new }
                object["EnvironmentVariables"] = variables
            }
            return object
        }
        if let array = value as? [Any] { return array.map { inject($0, environment: environment) } }
        return value
    }

    static func relocate(_ value: Any, from source: String, to destination: String) -> Any {
        if let object = value as? [String: Any] { return object.mapValues { relocate($0, from: source, to: destination) } }
        if let array = value as? [Any] { return array.map { relocate($0, from: source, to: destination) } }
        if let string = value as? String, string == source || string.hasPrefix(source + "/") { return destination + string.dropFirst(source.count) }
        return value
    }

    private static func containsTarget(_ value: Any, name: String) -> Bool {
        targetDictionaries(value).contains {
            $0["BlueprintName"] as? String == name || ($0["TestBundlePath"] as? String)?.hasSuffix("/\(name).xctest") == true
        }
    }

    private static func targetDictionaries(_ value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            return (object["TestBundlePath"] != nil ? [object] : []) + object.values.flatMap { targetDictionaries($0) }
        }
        if let array = value as? [Any] { return array.flatMap { targetDictionaries($0) } }
        return []
    }

    private static func read(_ file: URL) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
            throw MutationEngineError.invalidProject("Invalid Xcode test manifest: \(file.path)")
        }
        return plist
    }

    private static func write(_ data: [String: Any], to file: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: data, format: .xml, options: 0).write(to: file, options: .atomic)
    }
}
