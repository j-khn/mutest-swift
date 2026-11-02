import Foundation
import Testing
@testable import SwiftMutationTesting

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
        #expect(selection.identifiers == ["FixtureTests", "FixtureTests/FlowSuite/parameterized(value:)"])
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
        #expect(selection.identifiers == ["WidgetUnitTests", "WidgetUnitTests/WidgetTests/testWidget()"])
    }

    @Test("unions whole test targets with a test file resolved to another target")
    func wholeTargetsAndFileFromAnotherTarget() throws {
        let (root, ownership) = try multiTargetFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(files: ["Modules/TargetC/Tests/TargetCTests/FlowTests.swift"]),
            testTargets: ["TargetA", "TargetB"],
            targetByTestFile: ownership,
            forXcode: true
        )

        #expect(selection.identifiers == [
            "TargetA",
            "TargetB",
            "TargetCTests/FlowSuite/flowName()",
            "TargetCTests/FlowSuite/parameterized(value:)"
        ])
        #expect(selection.targets == ["TargetA", "TargetB", "TargetCTests"])
        #expect(!selection.allTests)
    }

    @Test("a test-file selector runs only its owning target when no full target is selected")
    func fileSelectorWithoutFullTarget() throws {
        let (root, ownership) = try multiTargetFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(files: ["Modules/TargetC/Tests/TargetCTests/FlowTests.swift"]),
            testTargets: [],
            targetByTestFile: ownership,
            forXcode: true
        )

        #expect(selection.identifiers == [
            "TargetCTests/FlowSuite/flowName()",
            "TargetCTests/FlowSuite/parameterized(value:)"
        ])
        #expect(selection.targets == ["TargetCTests"])
        #expect(!selection.allTests)
    }

    @Test("resolves suite and test-name selectors to their own targets")
    func suiteAndNameAcrossTargets() throws {
        let (root, ownership) = try multiTargetFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(
                suites: ["Suite E label"],
                tests: ["testNameABCInFileDEFAndTargetD"]
            ),
            testTargets: ["TargetA", "TargetB"],
            targetByTestFile: ownership,
            forXcode: true
        )

        #expect(selection.identifiers == [
            "TargetA",
            "TargetB",
            "TargetDTests/DEFTests/testNameABCInFileDEFAndTargetD()",
            "TargetETests/Suite1/suiteOne()",
            "TargetETests/Suite1/suiteTwo()"
        ])
        #expect(selection.targets == ["TargetA", "TargetB", "TargetDTests", "TargetETests"])
    }

    @Test("combines whole targets with a file, suite, and test from three other targets")
    func combinedTargetsAndCrossTargetSelectors() throws {
        let (root, ownership) = try multiTargetFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(
                files: ["Modules/TargetC/Tests/TargetCTests/FlowTests.swift"],
                suites: ["TargetETests::Suite1"],
                tests: ["TargetDTests::testNameABCInFileDEFAndTargetD"]
            ),
            testTargets: ["TargetA", "TargetB"],
            targetByTestFile: ownership,
            forXcode: true
        )

        #expect(selection.identifiers == [
            "TargetA",
            "TargetB",
            "TargetCTests/FlowSuite/flowName()",
            "TargetCTests/FlowSuite/parameterized(value:)" ,
            "TargetDTests/DEFTests/testNameABCInFileDEFAndTargetD()",
            "TargetETests/Suite1/suiteOne()",
            "TargetETests/Suite1/suiteTwo()"
        ])
        #expect(selection.targets == ["TargetA", "TargetB", "TargetCTests", "TargetDTests", "TargetETests"])
    }

    @Test("selects exactly matching tests when a test name occurs in multiple targets")
    func targetQualifiedDuplicateNames() throws {
        let (root, ownership) = try multiTargetFixture(duplicateAcrossTargets: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: TestSelectionError.self) {
            try SwiftTestSelectorResolver().resolve(
                projectRoot: root,
                selection: .init(tests: ["duplicateAcrossTargets"]),
                testTargets: [],
                targetByTestFile: ownership,
                forXcode: true
            )
        }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(tests: ["TargetCTests::duplicateAcrossTargets"]),
            testTargets: [],
            targetByTestFile: ownership,
            forXcode: true
        )
        #expect(selection.identifiers == ["TargetCTests/DuplicateSuite/duplicateAcrossTargets()"])
    }

    @Test("selects multiple whole Xcode test targets without expanding to the whole scheme")
    func multipleWholeTargets() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try SwiftTestSelectorResolver().resolve(
            projectRoot: root,
            selection: .init(),
            testTargets: ["FirstTests", "SecondTests"],
            forXcode: true
        )

        #expect(selection.identifiers == ["FirstTests", "SecondTests"])
        #expect(selection.targets == ["FirstTests", "SecondTests"])
        #expect(!selection.allTests)
    }

    @Test("passes target-wide and exact test filters together to xcodebuild")
    func xcodeCommandCombinesTargetAndExactSelectors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let adapter = NativeTestAdapter(
            project: .init(kind: .xcodeProject, path: "Fixture.xcodeproj", scheme: "Fixture", testTargets: ["TargetA", "TargetB"]),
            selection: .init(files: ["FlowTests.swift"])
        )
        let command = try adapter.command(
            root: root,
            phase: .testWithoutBuilding,
            resolved: .init(
                identifiers: ["TargetA", "TargetB", "TargetCTests/FlowSuite/flowName()"],
                allTests: false,
                targets: ["TargetA", "TargetB", "TargetCTests"]
            ),
            environment: [:],
            timeout: 10,
            output: root.appendingPathComponent("xcode.log")
        )

        #expect(command.arguments.filter { $0.hasPrefix("-only-testing:") } == [
            "-only-testing:TargetA",
            "-only-testing:TargetB",
            "-only-testing:TargetCTests/FlowSuite/flowName()"
        ])
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

    private func multiTargetFixture(duplicateAcrossTargets: Bool = false) throws -> (URL, [String: [String]]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { }
        let fixtures: [(String, String, String)] = [
            ("Modules/TargetC/Tests/TargetCTests/FlowTests.swift", "TargetCTests", """
            import Testing
            @Suite("Flow suite")
            struct FlowSuite {
                @Test("Flow name") func flowName() {}
                @Test("Parameterized", arguments: [1, 2]) func parameterized(value: Int) {}
            }
            """),
            ("Modules/TargetD/Tests/TargetDTests/DEFTests.swift", "TargetDTests", """
            import Testing
            struct DEFTests {
                @Test func testNameABCInFileDEFAndTargetD() {}
            }
            """),
            ("Modules/TargetE/Tests/TargetETests/SuiteTests.swift", "TargetETests", """
            import Testing
            @Suite("Suite E label")
            struct Suite1 {
                @Test func suiteOne() {}
                @Test func suiteTwo() {}
            }
            """)
        ]
        var ownership: [String: [String]] = [:]
        for (path, target, contents) in fixtures {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            ownership[path] = [target]
        }
        if duplicateAcrossTargets {
            for (path, target) in [
                ("Modules/TargetC/Tests/TargetCTests/OneTests.swift", "TargetCTests"),
                ("Modules/TargetD/Tests/TargetDTests/TwoTests.swift", "TargetDTests")
            ] {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "import Testing\nstruct DuplicateSuite { @Test func duplicateAcrossTargets() {} }\n".write(to: file, atomically: true, encoding: .utf8)
                ownership[path] = [target]
            }
        }
        return (root, ownership)
    }
}
