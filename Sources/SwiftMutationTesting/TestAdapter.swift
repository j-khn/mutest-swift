import Foundation
import SwiftParser
import SwiftSyntax
import MutationTestingSpec

public struct ResolvedTestSelection: Sendable {
    public var identifiers: [String]
    public var allTests: Bool
}

public enum TestSelectionError: Error, CustomStringConvertible {
    case unknown(String)
    case ambiguous(String, [String])
    case noTestsInFile(String)
    public var description: String {
        switch self {
        case .unknown(let selector): return "Test selector '\(selector)' did not match any discovered test."
        case .ambiguous(let selector, let matches): return "Test selector '\(selector)' is ambiguous; use a suite-qualified selector. Matches: \(matches.joined(separator: ", "))"
        case .noTestsInFile(let file): return "Test file selector '\(file)' matched no test declarations."
        }
    }
}

private struct DiscoveredTest {
    var file: String
    var suite: String
    var suiteLabel: String?
    var function: String
    var parameterLabels: [String]
    var customName: String?
    var xcodeFunction: String {
        function + (parameterLabels.isEmpty ? "()" : "(\(parameterLabels.map { $0 + ":" }.joined()))")
    }
}

/// Conservative source-based resolver: explicit selectors are mapped to test source declarations
/// before invoking a native runner. An absent selector leaves the runner's normal full-suite scope.
public struct SwiftTestSelectorResolver: Sendable {
    public init() {}

    public func resolve(projectRoot: URL, selection: TestSelection, testTarget: String? = nil, forXcode: Bool = false) throws -> ResolvedTestSelection {
        guard !selection.isEmpty else { return .init(identifiers: [], allTests: true) }
        let files: [(URL, String)]
        if forXcode {
            var discoveredFiles: [(URL, String)] = []
            if let enumerator = FileManager.default.enumerator(at: projectRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    let relative = String(file.path.dropFirst(projectRoot.path.count + 1))
                    let components = relative.split(separator: "/").map(String.init)
                    if components.contains(where: { [".git", ".build", ".swiftpm", ".swift-mutation-testing", "DerivedData"].contains($0) }) {
                        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                        continue
                    }
                    if file.pathExtension == "swift" { discoveredFiles.append((file, relative)) }
                }
            }
            files = discoveredFiles
        } else {
            let testRoot = projectRoot.appendingPathComponent("Tests", isDirectory: true)
            let relativeFiles = (try? FileManager.default.subpathsOfDirectory(atPath: testRoot.path))?.filter { $0.hasSuffix(".swift") } ?? []
            files = relativeFiles.map { (testRoot.appendingPathComponent($0), "Tests/\($0)") }
        }
        var discovered: [DiscoveredTest] = []
        for (url, relative) in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            discovered += Self.discover(text: text, relativeFile: relative)
        }

        var chosen = Set<String>()
        for requestedFile in selection.files {
            let matched = discovered.filter { $0.file == requestedFile || URL(fileURLWithPath: $0.file).lastPathComponent == URL(fileURLWithPath: requestedFile).lastPathComponent }
            guard !matched.isEmpty else { throw TestSelectionError.noTestsInFile(requestedFile) }
            let uniqueFiles = Set(matched.map(\.file))
            if uniqueFiles.count > 1 { throw TestSelectionError.ambiguous(requestedFile, uniqueFiles.sorted()) }
            matched.forEach { chosen.insert(Self.identifier($0, testTarget: testTarget, forXcode: forXcode)) }
        }
        for requested in selection.suites {
            let matches = discovered.filter { $0.suite == requested || $0.suiteLabel == requested }
            guard !matches.isEmpty else { throw TestSelectionError.unknown(requested) }
            let uniqueSuites = Set(matches.map(\.suite))
            if uniqueSuites.count > 1 { throw TestSelectionError.ambiguous(requested, uniqueSuites.sorted()) }
            matches.forEach { chosen.insert(Self.identifier($0, testTarget: testTarget, forXcode: forXcode)) }
        }
        for requested in selection.tests {
            let matches = discovered.filter { $0.function == requested || $0.customName == requested || Self.identifier($0, testTarget: testTarget, forXcode: forXcode).hasSuffix("/\(requested)") }
            guard !matches.isEmpty else { throw TestSelectionError.unknown(requested) }
            if matches.count > 1 { throw TestSelectionError.ambiguous(requested, matches.map { "\($0.suite)/\($0.function)" }.sorted()) }
            matches.forEach { chosen.insert(Self.identifier($0, testTarget: testTarget, forXcode: forXcode)) }
        }
        guard !chosen.isEmpty else { throw TestSelectionError.unknown("(empty selection)") }
        return .init(identifiers: chosen.sorted(), allTests: false)
    }

    private static func identifier(_ test: DiscoveredTest, testTarget: String?, forXcode: Bool) -> String {
        let function = forXcode ? test.xcodeFunction : test.function
        if let target = testTarget, !target.isEmpty { return "\(target)/\(test.suite)/\(function)" }
        return "\(test.suite)/\(function)"
    }

    private static func discover(text: String, relativeFile: String) -> [DiscoveredTest] {
        let visitor = TestDiscoveryVisitor(file: relativeFile)
        visitor.walk(Parser.parse(source: text))
        return visitor.tests
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
        let suite = suiteNames.last ?? URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let suiteLabel = suiteLabels.last ?? nil
        let custom = Self.customTestName(attributes)
        let parameterLabels = node.signature.parameterClause.parameters.map { $0.firstName.text }
        tests.append(.init(file: file, suite: suite, suiteLabel: suiteLabel, function: function, parameterLabels: parameterLabels, customName: custom))
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

public struct NativeTestAdapter: Sendable {
    public var project: ProjectConfiguration
    public var selection: TestSelection
    public init(project: ProjectConfiguration, selection: TestSelection) { self.project = project; self.selection = selection }

    public func command(root: URL, phase: TestPhase, resolved: ResolvedTestSelection, environment: [String: String], timeout: TimeInterval, output: URL) throws -> CommandSpec {
        switch project.kind {
        case .swiftPackage:
            let args: [String]
            switch phase {
            case .testWithoutBuilding: args = ["test", "--skip-build"]
            case .buildForTesting: args = ["build", "--build-tests"]
            case .baseline: args = ["test"]
            }
            var finalArgs = args
            if phase != .buildForTesting, !resolved.allTests, !resolved.identifiers.isEmpty {
                let pattern = resolved.identifiers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                finalArgs += ["--filter", pattern]
            }
            return .init(executable: "/usr/bin/swift", arguments: finalArgs, workingDirectory: root, environment: environment, timeout: timeout, outputFile: output)
        case .xcodeProject, .xcodeWorkspace:
            guard let scheme = project.scheme, !scheme.isEmpty else { throw ContractError.invalidConfiguration("Xcode projects and workspaces require --scheme.") }
            let projectPath = root.appendingPathComponent(project.path).path
            let action: String
            switch phase {
            case .testWithoutBuilding: action = "test-without-building"
            case .buildForTesting: action = "build-for-testing"
            case .baseline: action = "test"
            }
            var args = ["xcodebuild", action]
            args += project.kind == .xcodeWorkspace ? ["-workspace", projectPath] : ["-project", projectPath]
            args += ["-scheme", scheme]
            if let destination = project.destination { args += ["-destination", destination] }
            args.append("-derivedDataPath")
            args.append(root.appendingPathComponent(".swift-mutation-testing/DerivedData").path)
            if resolved.allTests, let testTarget = project.testTarget, !testTarget.isEmpty {
                args.append("-only-testing:\(testTarget)")
            } else {
                // Xcode's test enumeration uses `()` for zero-argument tests and preserves
                // argument labels for parameterized tests. Omitting the suffix can silently
                // select zero tests while xcodebuild still exits successfully.
                for identifier in resolved.identifiers {
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
            return .init(executable: "/usr/bin/xcrun", arguments: args, workingDirectory: root, environment: runnerEnvironment, timeout: timeout, outputFile: output)
        }
    }
}

public enum TestPhase: Sendable, Equatable { case baseline, buildForTesting, testWithoutBuilding }
