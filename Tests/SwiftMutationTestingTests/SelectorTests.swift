import Foundation
import Testing
@testable import SwiftMutationTesting
import MutationTestingSpec

@Suite("Test selector resolution")
struct SelectorTests {
    @Test("maps a file, custom suite, and custom test name to runner identifiers")
    func selectors() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SwiftTestSelectorResolver()
        let file = try resolver.resolve(projectRoot: root, selection: .init(files: ["FlowTests.swift"]))
        #expect(file.identifiers == ["FlowSuite/flowName", "FlowSuite/parameterized"])
        let suite = try resolver.resolve(projectRoot: root, selection: .init(suites: ["Readable suite"]))
        #expect(suite.identifiers == ["FlowSuite/flowName", "FlowSuite/parameterized"])
        let test = try resolver.resolve(projectRoot: root, selection: .init(tests: ["Friendly test label"]))
        #expect(test.identifiers == ["FlowSuite/flowName"])
    }

    @Test("discovers XCTest test methods and rejects unknown selectors")
    func xctestAndUnknown() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = SwiftTestSelectorResolver()
        let selected = try resolver.resolve(projectRoot: root, selection: .init(tests: ["testLegacyBehavior"]))
        #expect(selected.identifiers == ["LegacyTests/testLegacyBehavior"])
        #expect(throws: TestSelectionError.self) {
            try resolver.resolve(projectRoot: root, selection: .init(tests: ["missingTest"]))
        }
    }

    @Test("rejects ambiguous test names rather than widening the selection")
    func ambiguous() throws {
        let root = try fixtureRoot(ambiguous: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: TestSelectionError.self) {
            try SwiftTestSelectorResolver().resolve(projectRoot: root, selection: .init(tests: ["duplicateName"]))
        }
    }

    @Test("formats selected Xcode tests with the function suffix Xcode enumerates")
    func xcodeIdentifierFormatting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let adapter = NativeTestAdapter(
            project: .init(kind: .xcodeProject, path: "Fixture.xcodeproj", scheme: "Fixture", testTarget: "FixtureTests"),
            selection: .init(tests: ["Friendly test label"])
        )
        let command = try adapter.command(
            root: root,
            phase: .testWithoutBuilding,
            resolved: .init(identifiers: ["FixtureTests/FlowSuite/flowName"], allTests: false),
            environment: [:],
            timeout: 10,
            output: root.appendingPathComponent("xcode.log")
        )
        #expect(command.arguments.contains("-only-testing:FixtureTests/FlowSuite/flowName()"))
    }

    @Test("does not pass test filters to SwiftPM build commands")
    func packageBuildIgnoresTestFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let adapter = NativeTestAdapter(project: .init(kind: .swiftPackage, path: "."), selection: .init(tests: ["flowName"]))
        let command = try adapter.command(
            root: root,
            phase: .buildForTesting,
            resolved: .init(identifiers: ["FlowSuite/flowName"], allTests: false),
            environment: [:],
            timeout: 10,
            output: root.appendingPathComponent("build.log")
        )
        #expect(!command.arguments.contains("--filter"))
        #expect(command.arguments.contains("--build-tests"))
    }

    @Test("passes an isolated SwiftPM scratch path to mutation test commands")
    func packageMutationUsesWorkerScratchPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let scratch = root.appendingPathComponent("worker-build")
        let adapter = NativeTestAdapter(project: .init(kind: .swiftPackage, path: "."), selection: .init())
        let command = try adapter.command(
            root: root,
            phase: .testWithoutBuilding,
            resolved: .init(identifiers: [], allTests: true),
            environment: ["SWIFT_MUTATION_ID": "mutant"],
            timeout: 10,
            output: root.appendingPathComponent("test.log"),
            scratchPath: scratch
        )
        #expect(command.arguments.contains("--skip-build"))
        #expect(command.arguments.contains("--scratch-path"))
        #expect(command.arguments.contains(scratch.path))
    }

    @Test("preserves Xcode parameter labels for parameterized Swift Testing declarations")
    func parameterizedXcodeIdentifier() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(tests: ["parameterized"]),
            testTarget: "FixtureTests",
            forXcode: true
        )
        #expect(selection.identifiers == ["FixtureTests/FlowSuite/parameterized(value:)"])
    }

    @Test("discovers Xcode test files outside a top-level Tests directory")
    func xcodeTestsOutsideTestsDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testDirectory = root.appendingPathComponent("WidgetUnitTests", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "import XCTest\nfinal class WidgetTests: XCTestCase { func testWidget() {} }\n".write(
            to: testDirectory.appendingPathComponent("WidgetTests.swift"),
            atomically: true,
            encoding: .utf8
        )
        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(files: ["WidgetUnitTests/WidgetTests.swift"]),
            testTarget: "WidgetUnitTests",
            forXcode: true
        )
        #expect(selection.identifiers == ["WidgetUnitTests/WidgetTests/testWidget()"])
    }

    private func fixtureRoot(ambiguous: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tests = root.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let source = """
        import Testing
        @Suite("Readable suite")
        struct FlowSuite {
            @Test("Friendly test label")
            func flowName() {}

            @Test("Parameterized test", arguments: [1, 2])
            func parameterized(value: Int) {}
        }
        """
        let legacy = """
        import XCTest
        final class LegacyTests: XCTestCase {
            func testLegacyBehavior() {}
        }
        """
        try source.write(to: tests.appendingPathComponent("FlowTests.swift"), atomically: true, encoding: .utf8)
        try legacy.write(to: tests.appendingPathComponent("LegacyTests.swift"), atomically: true, encoding: .utf8)
        if ambiguous {
            let duplicate = "import Testing\nstruct AnotherSuite { @Test func duplicateName() {} }\nstruct ThirdSuite { @Test func duplicateName() {} }\n"
            try duplicate.write(to: tests.appendingPathComponent("DuplicateTests.swift"), atomically: true, encoding: .utf8)
        }
        return root
    }
}
