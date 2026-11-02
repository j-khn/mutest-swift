import Foundation
import SwiftParser
import SwiftSyntax

public struct ResolvedTestSelection: Sendable {
    public var identifiers: [String]
    public var allTests: Bool
    public var targets: [String]

    public init(identifiers: [String], allTests: Bool, targets: [String] = []) {
        self.identifiers = identifiers
        self.allTests = allTests
        self.targets = targets
    }
}

public enum TestSelectionError: Error, CustomStringConvertible {
    case unknown(String)
    case ambiguous(String, [String])
    case noTestsInFile(String)
    case targetUnresolved(String, String)
    public var description: String {
        switch self {
        case .unknown(let selector): return "Test selector '\(selector)' did not match any discovered test."
        case .ambiguous(let selector, let matches): return "Test selector '\(selector)' is ambiguous; qualify it as TargetName::selector. Matches: \(matches.joined(separator: ", "))"
        case .noTestsInFile(let file): return "Test file selector '\(file)' matched no test declarations."
        case .targetUnresolved(let selector, let file): return "Cannot determine which Xcode test target contains selector '\(selector)' in '\(file)'. Add the test target to the Xcode scheme or use a target-qualified selector such as 'TargetName::\(selector)'."
        }
    }
}

private struct DiscoveredTest {
    var file: String
    var absoluteFile: String
    var targets: [String]
    var suite: String
    var suiteLabel: String?
    var function: String
    var parameterLabels: [String]
    var customName: String?
    var isTopLevel: Bool
    var xcodeFunction: String {
        function + (parameterLabels.isEmpty ? "()" : "(\(parameterLabels.map { $0 + ":" }.joined()))")
    }
}

/// Conservative source-based resolver: explicit selectors are mapped to test source declarations
/// before invoking a native runner. An absent selector leaves the runner's normal full-suite scope.
public struct SwiftTestSelectorResolver: Sendable {
    public init() {}

    public func resolve(projectRoot: URL, selection: TestSelection, testTarget: String? = nil, forXcode: Bool = false) throws -> ResolvedTestSelection {
        try resolve(
            projectRoot: projectRoot,
            selection: selection,
            testTargets: testTarget.map { [$0] } ?? [],
            targetByTestFile: [:],
            forXcode: forXcode,
            allowImplicitSingleTarget: true
        )
    }

    public func resolve(
        projectRoot: URL,
        selection: TestSelection,
        testTargets: [String],
        targetByTestFile: [String: [String]] = [:],
        forXcode: Bool = false
    ) throws -> ResolvedTestSelection {
        try resolve(
            projectRoot: projectRoot,
            selection: selection,
            testTargets: testTargets,
            targetByTestFile: targetByTestFile,
            forXcode: forXcode,
            allowImplicitSingleTarget: false
        )
    }

    private func resolve(
        projectRoot: URL,
        selection: TestSelection,
        testTargets: [String],
        targetByTestFile: [String: [String]],
        forXcode: Bool,
        allowImplicitSingleTarget: Bool
    ) throws -> ResolvedTestSelection {
        let explicitTargets = Self.unique(testTargets)
        guard !selection.isEmpty else {
            if forXcode, !explicitTargets.isEmpty {
                return .init(identifiers: explicitTargets, allTests: false, targets: explicitTargets)
            }
            return .init(identifiers: [], allTests: true)
        }
        let root = projectRoot.standardizedFileURL
        let targetMap = Self.normalizedTargetMap(targetByTestFile, root: root)
        var fileURLs: [URL] = []
        if forXcode {
            if !targetMap.isEmpty {
                fileURLs = targetMap.keys.map { URL(fileURLWithPath: $0) }
            } else if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    let relative = String(file.path.dropFirst(root.path.count + 1))
                    if ProjectFilePaths.isGenerated(relative) {
                        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                        continue
                    }
                    if file.pathExtension == "swift" { fileURLs.append(file.standardizedFileURL) }
                }
            }
        } else {
            let testRoot = root.appendingPathComponent("Tests", isDirectory: true)
            let relativeFiles = (try? FileManager.default.subpathsOfDirectory(atPath: testRoot.path))?.filter { $0.hasSuffix(".swift") } ?? []
            fileURLs = relativeFiles.map { testRoot.appendingPathComponent($0).standardizedFileURL }
        }
        if forXcode {
            fileURLs += targetMap.keys.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        fileURLs = Array(Dictionary(grouping: fileURLs, by: \.path).values.compactMap(\.first)).sorted { $0.path < $1.path }
        var discovered: [DiscoveredTest] = []
        for url in fileURLs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let absolutePath = url.standardizedFileURL.path
            let relative = PackageDependencyResolver.relativePath(url, to: root)
            var targets = targetMap[absolutePath] ?? targetMap[relative] ?? []
            if forXcode, targets.isEmpty, explicitTargets.count == 1, allowImplicitSingleTarget {
                targets = explicitTargets
            }
            discovered += Self.discover(text: text, relativeFile: relative, absoluteFile: absolutePath, targets: targets)
        }

        var chosen = Set<String>(forXcode ? explicitTargets : [])
        var selectedTargets = Set(explicitTargets)
        for requestedFile in selection.files {
            let (qualifiedTarget, fileSelector) = Self.splitQualifiedSelector(requestedFile)
            let normalizedRequested = URL(fileURLWithPath: fileSelector, relativeTo: root).standardizedFileURL.path
            let matched = discovered.filter {
                (qualifiedTarget == nil || $0.targets.isEmpty || $0.targets.contains(qualifiedTarget!))
                    && ($0.file == fileSelector
                    || $0.absoluteFile == normalizedRequested
                    || URL(fileURLWithPath: $0.file).lastPathComponent == URL(fileURLWithPath: fileSelector).lastPathComponent)
            }
            guard !matched.isEmpty else { throw TestSelectionError.noTestsInFile(requestedFile) }
            let uniqueFiles = Set(matched.map(\.file))
            if uniqueFiles.count > 1 { throw TestSelectionError.ambiguous(requestedFile, uniqueFiles.sorted()) }
            for test in matched {
                let targets = try Self.targets(for: test, selector: requestedFile, qualifiedTarget: qualifiedTarget, forXcode: forXcode)
                selectedTargets.formUnion(targets)
                if targets.isEmpty { chosen.insert(Self.identifier(test, target: nil, forXcode: forXcode)) }
                else { for target in targets { chosen.insert(Self.identifier(test, target: target, forXcode: forXcode)) } }
            }
        }
        for requested in selection.suites {
            let (qualifiedTarget, selector) = Self.splitQualifiedSelector(requested)
            let matches = discovered.filter {
                (qualifiedTarget == nil || $0.targets.isEmpty || $0.targets.contains(qualifiedTarget!))
                    && ($0.suite == selector || $0.suiteLabel == selector)
            }
            guard !matches.isEmpty else { throw TestSelectionError.unknown(requested) }
            let uniqueSuites = Set(matches.map { "\($0.targets.first ?? "")/\($0.suite)" })
            if uniqueSuites.count > 1 { throw TestSelectionError.ambiguous(requested, matches.map { Self.describe($0, forXcode: forXcode) }.sorted()) }
            for test in matches {
                let targets = try Self.targets(for: test, selector: requested, qualifiedTarget: qualifiedTarget, forXcode: forXcode)
                selectedTargets.formUnion(targets)
                if targets.isEmpty { chosen.insert(Self.identifier(test, target: nil, forXcode: forXcode)) }
                else { for target in targets { chosen.insert(Self.identifier(test, target: target, forXcode: forXcode)) } }
            }
        }
        for requested in selection.tests {
            let (qualifiedTarget, selector) = Self.splitQualifiedSelector(requested)
            let matches = discovered.filter { test in
                guard qualifiedTarget == nil || test.targets.isEmpty || test.targets.contains(qualifiedTarget!) else { return false }
                return test.function == selector
                    || test.customName == selector
                    || Self.identifier(test, target: test.targets.first, forXcode: forXcode).hasSuffix("/\(selector)")
                    || Self.identifier(test, target: test.targets.first, forXcode: forXcode) == selector
            }
            guard !matches.isEmpty else { throw TestSelectionError.unknown(requested) }
            var identifiers = Set<String>()
            for test in matches {
                let targets = try Self.targets(for: test, selector: requested, qualifiedTarget: qualifiedTarget, forXcode: forXcode)
                if targets.isEmpty { identifiers.insert(Self.identifier(test, target: nil, forXcode: forXcode)) }
                else { for target in targets { identifiers.insert(Self.identifier(test, target: target, forXcode: forXcode)) } }
            }
            if identifiers.count > 1 { throw TestSelectionError.ambiguous(requested, identifiers.sorted()) }
            for test in matches {
                let targets = try Self.targets(for: test, selector: requested, qualifiedTarget: qualifiedTarget, forXcode: forXcode)
                selectedTargets.formUnion(targets)
                if targets.isEmpty { chosen.insert(Self.identifier(test, target: nil, forXcode: forXcode)) }
                else { for target in targets { chosen.insert(Self.identifier(test, target: target, forXcode: forXcode)) } }
            }
        }
        guard !chosen.isEmpty else { throw TestSelectionError.unknown("(empty selection)") }
        return .init(identifiers: chosen.sorted(), allTests: false, targets: selectedTargets.sorted())
    }

    private static func identifier(_ test: DiscoveredTest, target: String?, forXcode: Bool) -> String {
        let function = forXcode ? test.xcodeFunction : test.function
        guard forXcode else { return test.isTopLevel ? function : "\(test.suite)/\(function)" }
        guard let target, !target.isEmpty else { return test.isTopLevel ? function : "\(test.suite)/\(function)" }
        if test.isTopLevel {
            return "\(target)/\(function)"
        }
        return "\(target)/\(test.suite)/\(function)"
    }

    private static func targets(for test: DiscoveredTest, selector: String, qualifiedTarget: String?, forXcode: Bool) throws -> [String] {
        guard forXcode else { return [] }
        if !test.targets.isEmpty { return test.targets }
        if let qualifiedTarget { return [qualifiedTarget] }
        throw TestSelectionError.targetUnresolved(selector, test.file)
    }

    private static func describe(_ test: DiscoveredTest, forXcode: Bool) -> String {
        let identifier = test.targets.first.map { Self.identifier(test, target: $0, forXcode: forXcode) } ?? "\(test.suite)/\(test.function)"
        return identifier
    }

    private static func splitQualifiedSelector(_ selector: String) -> (String?, String) {
        guard let separator = selector.range(of: "::") else { return (nil, selector) }
        return (String(selector[..<separator.lowerBound]), String(selector[separator.upperBound...]))
    }

    private static func normalizedTargetMap(_ map: [String: [String]], root: URL) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (path, targets) in map {
            let absolute = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL.path
            result[absolute, default: []] += targets
        }
        for path in result.keys { result[path] = unique(result[path] ?? []) }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values where !value.isEmpty && !result.contains(value) { result.append(value) }
        return result.sorted()
    }

    private static func discover(text: String, relativeFile: String, absoluteFile: String, targets: [String]) -> [DiscoveredTest] {
        let visitor = TestDiscoveryVisitor(file: relativeFile)
        visitor.walk(Parser.parse(source: text))
        return visitor.tests.map {
            var test = $0
            test.absoluteFile = absoluteFile
            test.targets = targets
            return test
        }
    }
}

private final class TestDiscoveryVisitor: SyntaxVisitor {
    let file: String
    var tests: [DiscoveredTest] = []
    private var suiteNames: [String] = []
    private var suiteLabels: [String?] = []
    init(file: String) { self.file = file; super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        pushSuite(name: node.name.text, attributes: node.attributes.description); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { popSuite() }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        pushSuite(name: node.name.text, attributes: node.attributes.description); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { popSuite() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        pushSuite(name: node.name.text, attributes: node.attributes.description); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { popSuite() }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let function = node.name.text
        let attributes = node.attributes.description
        let isTesting = attributes.contains("Test") || function.hasPrefix("test")
        guard isTesting else { return .visitChildren }
        let suite = suiteNames.last ?? ""
        let suiteLabel = suiteLabels.last ?? nil
        let custom = Self.customTestName(attributes)
        let parameterLabels = node.signature.parameterClause.parameters.map { $0.firstName.text }
        tests.append(.init(file: file, absoluteFile: "", targets: [], suite: suite, suiteLabel: suiteLabel, function: function, parameterLabels: parameterLabels, customName: custom, isTopLevel: suiteNames.isEmpty))
        return .visitChildren
    }

    private func pushSuite(name: String, attributes: String) {
        suiteNames.append(name)
        suiteLabels.append(Self.customSuiteName(attributes))
    }
    private func popSuite() {
        if !suiteNames.isEmpty { suiteNames.removeLast() }
        if !suiteLabels.isEmpty { suiteLabels.removeLast() }
    }

    private static func customTestName(_ attributes: String) -> String? {
        guard let range = attributes.range(of: #"@Test\s*\(\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let matched = String(attributes[range])
        guard let start = matched.firstIndex(of: "\""), let end = matched[matched.index(after: start)...].firstIndex(of: "\"") else { return nil }
        return String(matched[matched.index(after: start)..<end])
    }
    private static func customSuiteName(_ attributes: String) -> String? {
        guard let range = attributes.range(of: #"@Suite\s*\(\s*"([^"]+)""#, options: .regularExpression) else { return nil }
        let matched = String(attributes[range])
        guard let start = matched.firstIndex(of: "\""), let end = matched[matched.index(after: start)...].firstIndex(of: "\"") else { return nil }
        return String(matched[matched.index(after: start)..<end])
    }
}

public struct XcodeTestExecutionContext: Sendable {
    public var destination: String
    public var derivedDataPath: URL
    public var testRunFile: URL?
    public var resultBundlePath: URL?

    public init(destination: String, derivedDataPath: URL, testRunFile: URL? = nil, resultBundlePath: URL? = nil) {
        self.destination = destination; self.derivedDataPath = derivedDataPath
        self.testRunFile = testRunFile; self.resultBundlePath = resultBundlePath
    }
}

enum XcodeSimulatorBuildSettings {
    static func defaults(for arguments: [String], destination: String?) -> [String] {
        guard destination?.localizedCaseInsensitiveContains("simulator") == true else { return [] }
        let hasArchitectureOverride = arguments.contains { argument in
            argument.hasPrefix("ARCHS=") || argument.hasPrefix("ONLY_ACTIVE_ARCH=")
        }
        guard !hasArchitectureOverride else { return [] }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        return []
        #endif

        // Xcode may build the app target for both simulator architectures while Swift
        // package products in the same build only contain the host architecture. Pin the
        // mutation build to the simulator architecture available on this Mac.
        return ["ARCHS=\(architecture)", "ONLY_ACTIVE_ARCH=YES"]
    }
}

public struct NativeTestAdapter: Sendable {
    public var project: ProjectConfiguration
    public var selection: TestSelection
    public var xcodebuildArguments: [String]
    public var xcodeDerivedDataPath: URL?
    public init(project: ProjectConfiguration, selection: TestSelection, xcodebuildArguments: [String] = [], xcodeDerivedDataPath: URL? = nil) {
        self.project = project; self.selection = selection; self.xcodebuildArguments = xcodebuildArguments
        self.xcodeDerivedDataPath = xcodeDerivedDataPath
    }

    public func command(root: URL, phase: TestPhase, resolved: ResolvedTestSelection, environment: [String: String], timeout: TimeInterval, output: URL, scratchPath: URL? = nil, stopOnActivatedTestFailure: Bool = false, activationID: String? = nil, activationFile: URL? = nil, xcodeContext: XcodeTestExecutionContext? = nil) throws -> CommandSpec {
        switch project.kind {
        case .swiftPackage:
            let args: [String]
            switch phase {
            case .resolveDependencies: args = ["package", "resolve"]
            case .testWithoutBuilding: args = ["test", "--skip-build"]
            case .buildForTesting: args = ["build", "--build-tests"]
            case .baseline: args = ["test"]
            }
            if phase == .resolveDependencies {
                return .init(executable: "/usr/bin/swift", arguments: args, workingDirectory: root, environment: environment, timeout: timeout, outputFile: output)
            }
            var finalArgs = args
            if phase == .testWithoutBuilding, let scratchPath {
                finalArgs += ["--scratch-path", scratchPath.path]
            }
            if phase != .buildForTesting, !resolved.allTests, !resolved.identifiers.isEmpty {
                // Swift Testing may append source-location components after a function's
                // signature. Match the declaration boundary, not the end of the whole ID.
                let pattern = resolved.identifiers.map { "(?:^|[./])" + NSRegularExpression.escapedPattern(for: $0) + #"(?:\(|$)"# }.joined(separator: "|")
                finalArgs += ["--filter", pattern]
            }
            return .init(executable: "/usr/bin/swift", arguments: finalArgs, workingDirectory: root, environment: environment, timeout: timeout, outputFile: output, stopOnActivatedTestFailure: stopOnActivatedTestFailure, activationID: activationID, activationFile: activationFile)
        case .xcodeProject, .xcodeWorkspace:
            guard let scheme = project.scheme, !scheme.isEmpty else { throw ContractError.invalidConfiguration("Xcode projects and workspaces require --scheme.") }
            let projectPath = root.appendingPathComponent(project.path).path
            let action: String
            switch phase {
            case .resolveDependencies: action = "-resolvePackageDependencies"
            case .testWithoutBuilding: action = "test-without-building"
            case .buildForTesting: action = "build-for-testing"
            case .baseline: action = "test"
            }
            var args = ["xcodebuild", action]
            if phase == .resolveDependencies {
                args += project.kind == .xcodeWorkspace ? ["-workspace", projectPath] : ["-project", projectPath]
                args += ["-scheme", scheme]
                if let derivedDataPath = xcodeContext?.derivedDataPath ?? xcodeDerivedDataPath {
                    args += ["-clonedSourcePackagesDirPath", derivedDataPath.appendingPathComponent("SourcePackages", isDirectory: true).path]
                }
                return .init(executable: "/usr/bin/xcrun", arguments: args, workingDirectory: root, environment: environment, timeout: timeout, outputFile: output)
            }
            let destination = xcodeContext?.destination ?? project.destination
            if phase == .buildForTesting || phase == .baseline {
                // Worker count controls tests, not Xcode's independent build scheduler.
                args += ["-jobs", "2"]
            }
            if phase == .testWithoutBuilding, let manifest = xcodeContext?.testRunFile {
                args += ["-xctestrun", manifest.path]
            } else {
                args += project.kind == .xcodeWorkspace ? ["-workspace", projectPath] : ["-project", projectPath]
                args += ["-scheme", scheme]
                args += xcodebuildArguments
                args += XcodeSimulatorBuildSettings.defaults(for: xcodebuildArguments, destination: destination)
            }
            if let destination { args += ["-destination", destination] }
            args += ["-derivedDataPath", (xcodeContext?.derivedDataPath ?? xcodeDerivedDataPath ?? root.appendingPathComponent(".swift-mutation-testing/DerivedData")).path]
            args += ["-parallel-testing-enabled", "NO"]
            if stopOnActivatedTestFailure {
                // Expected mutant failures do not need a full simulator sysdiagnose.
                args += ["-collect-test-diagnostics", "never"]
            }
            if let bundle = xcodeContext?.resultBundlePath { args += ["-resultBundlePath", bundle.path] }
            if resolved.allTests {
                for testTarget in project.testTargets where !testTarget.isEmpty {
                    args.append("-only-testing:\(testTarget)")
                }
            } else {
                // Xcode's test enumeration uses `()` for zero-argument tests and preserves
                // argument labels for parameterized tests. Omitting the suffix can silently
                // select zero tests while xcodebuild still exits successfully.
                for identifier in resolved.identifiers {
                    if resolved.targets.contains(identifier), !identifier.contains("/") {
                        args.append("-only-testing:\(identifier)")
                        continue
                    }
                    let hasFunctionSuffix = identifier.split(separator: "/").last?.hasSuffix(")") == true
                    let xcodeIdentifier = hasFunctionSuffix ? identifier : identifier + "()"
                    args.append("-only-testing:\(xcodeIdentifier)")
                }
            }
            // xcodebuild reserves TEST_RUNNER_* variables and removes that prefix when it
            // launches the XCTest/Swift Testing process. Plain shell variables are not reliably
            // forwarded to simulator test hosts.
            var runnerEnvironment = environment
            for (key, value) in environment where key.hasPrefix("SWIFT_MUTATION_") {
                runnerEnvironment.removeValue(forKey: key)
                runnerEnvironment["TEST_RUNNER_\(key)"] = value
            }
            return .init(executable: "/usr/bin/xcrun", arguments: args, workingDirectory: root, environment: runnerEnvironment, timeout: timeout, outputFile: output, stopOnActivatedTestFailure: stopOnActivatedTestFailure, activationID: activationID, activationFile: activationFile)
        }
    }
}

public enum TestPhase: Sendable, Equatable { case resolveDependencies, baseline, buildForTesting, testWithoutBuilding }
