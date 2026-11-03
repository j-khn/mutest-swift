import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Mutation engine integration", .serialized)
struct MutationEngineIntegrationTests {
    @Test("classifies killed, survived, and no-coverage mutants and resumes cached verdicts")
    func verdictsAndResume() throws {
        let fixture = try makePackage(
            source: """
            public enum Rules {
                public static func detected(_ value: Int) -> Int { value + 2 }
                public static func equivalent(_ value: Int) -> Int { value + 0 }
                public static func uncovered(_ value: Int) -> Int { value + 1 }
            }
            """,
            tests: """
            import Logic
            import Testing

            @Suite struct LogicTests {
            @Test("checks selected arithmetic rules")
            func checkRules() {
                #expect(Rules.detected(3) == 5)
                #expect(Rules.equivalent(3) == 3)
            }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        let cache = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-cache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: cache)
        }
        var configuration = configuration(for: fixture.root, testName: "checks selected arithmetic rules", operators: [.arithmetic])
        configuration.cache.path = cache.path

        let first = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        #expect(first.mutants.count == 3)
        #expect(first.summary.killed == 1)
        #expect(first.summary.survived == 1)
        #expect(first.summary.noCoverage == 1)
        #expect(first.mutants.first(where: { $0.status == .killed })?.activated == true)
        #expect(first.mutants.first(where: { $0.status == .survived })?.activated == true)
        #expect(first.mutants.first(where: { $0.status == .noCoverage })?.activated == false)

        let journal = cache.appendingPathComponent("journal.jsonl")
        let initialJournalLineCount = try String(contentsOf: journal, encoding: .utf8).split(whereSeparator: \.isNewline).count
        let resumed = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        let resumedJournalLineCount = try String(contentsOf: journal, encoding: .utf8).split(whereSeparator: \.isNewline).count
        #expect(resumed.summary.killed == first.summary.killed)
        #expect(resumed.summary.survived == first.summary.survived)
        #expect(resumed.summary.noCoverage == first.summary.noCoverage)
        #expect(resumedJournalLineCount == initialJournalLineCount)

        try "resource change invalidates the verdict cache".write(
            to: fixture.root.appendingPathComponent("cache-input.txt"),
            atomically: true,
            encoding: .utf8
        )
        let invalidated = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        let invalidatedJournalLineCount = try String(contentsOf: journal, encoding: .utf8).split(whereSeparator: \.isNewline).count
        #expect(invalidated.summary.killed == first.summary.killed)
        #expect(invalidatedJournalLineCount > resumedJournalLineCount)
    }

    @Test("reports type-invalid mutants as unbuildable after isolated fallback")
    func unbuildableMutant() throws {
        let fixture = try makePackage(
            source: #"public enum Rules { public static func join(_ left: String, _ right: String) -> String { left + right } }"#,
            tests: """
            import Logic
            import Testing

            @Suite struct LogicTests {
            @Test("joins text")
            func joinsText() { #expect(Rules.join("a", "b") == "ab") }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let configuration = configuration(for: fixture.root, operators: [.arithmetic])

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        #expect(report.summary.unbuildable == 1)
        #expect(report.summary.score == nil)
    }

    @Test("narrows an incompatible schema and keeps compatible mutants in a shared build")
    func narrowsIncompatibleSchema() throws {
        let source = """
        public enum Rules {
            public static func join(_ left: String, _ right: String) -> String { left + right }
            public static func enabled(_ value: Bool) -> Bool { value && true }
        }
        """
        let fixture = try makePackage(
            source: source,
            tests: """
            import Logic
            import Testing

            @Test("checks compatible and incompatible candidates")
            func checksRules() {
                #expect(Rules.join("a", "b") == "ab")
                #expect(Rules.enabled(true))
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let configuration = configuration(for: fixture.root, operators: [.arithmetic, .boolean])

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        let candidates = SwiftMutationGenerator().generate(source: source, relativePath: "Sources/Logic/Rules.swift", operators: [.arithmetic, .boolean])
        let boolean = try #require(candidates.first(where: { $0.operatorID == .boolean }))
        let invalidArithmetic = try #require(candidates.first(where: { $0.operatorID == .arithmetic }))

        #expect(report.summary.killed == 1)
        #expect(report.summary.unbuildable == 1)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/mutant-\(boolean.id).log").path))
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/isolated-build-\(boolean.id).log").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/isolated-build-\(invalidArithmetic.id).log").path))
    }

    @Test("runs two statement mutants with Swift Testing workers")
    func parallelStatementMutants() throws {
        let source = """
        public enum Rules {
            public static func both() {
                record("left")
                record("right")
            }
            private static func record(_ value: String) {}
        }
        """
        let fixture = try makePackage(
            source: source,
            tests: """
            import Logic
            import Testing

            @Test("calls both statement functions")
            func callsFunctions() {
                Rules.both()
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var configuration = configuration(for: fixture.root, operators: [.removeSideEffects])
        configuration.parallelism = 2

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        #expect(report.mutants.count == 2)
        #expect(report.summary.survived == 2)
        #expect(report.mutants.allSatisfy { $0.activated && $0.status == .survived })
        #expect(report.mutants.allSatisfy { FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/mutant-\($0.id).log").path) })
    }

    @Test("keeps expression-bodied side-effect mutants from forcing the whole schema into isolated builds")
    func statementFormMutantsDoNotDisableSchema() throws {
        let source = """
        public enum Rules {
            public static func sum(_ left: Int, _ right: Int) -> Int { return left + right }
            public static func clamped(_ value: Int) -> Int { max(0, value) }
        }
        """
        let fixture = try makePackage(
            source: source,
            tests: """
            import Logic
            import Testing

            @Test("checks arithmetic and clamping")
            func checksRules() {
                #expect(Rules.sum(2, 2) == 4)
                #expect(Rules.clamped(3) == 3)
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let configuration = configuration(for: fixture.root, testName: "checks arithmetic and clamping", operators: [.arithmetic, .removeSideEffects])

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        let arithmetic = try #require(SwiftMutationGenerator().generate(
            source: source,
            relativePath: "Sources/Logic/Rules.swift",
            operators: [.arithmetic]
        ).first)
        let sharedSchemaMutantLog = output.appendingPathComponent("logs/mutant-\(arithmetic.id).log")
        let isolatedArithmeticBuildLog = output.appendingPathComponent("logs/isolated-build-\(arithmetic.id).log")

        #expect(report.summary.killed == 1)
        #expect(report.summary.unbuildable == 0)
        #expect(FileManager.default.fileExists(atPath: sharedSchemaMutantLog.path))
        #expect(!FileManager.default.fileExists(atPath: isolatedArithmeticBuildLog.path))
    }

    @Test("aborts without a score when baseline tests fail")
    func baselineFailure() throws {
        let fixture = try makePackage(
            source: "public enum Rules { public static func value() -> Int { true ? 1 : 2 } }",
            tests: """
            import Logic
            import Testing

            @Suite struct LogicTests {
            @Test("fails baseline")
            func failsBaseline() { #expect(Rules.value() == 99) }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let configuration = configuration(for: fixture.root, testName: "fails baseline", operators: [.boolean])

        var didAbort = false
        do {
            _ = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        } catch let error as MutationEngineError {
            if case .baselineFailed(_, let timedOut) = error {
                didAbort = !timedOut
            }
        }
        #expect(didAbort)
        #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("report.json").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/schema-build.log").path))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("logs/baseline.log").path))
    }

    @Test("records a timeout as detected only after activation is verified")
    func activatedTimeout() throws {
        let fixture = try makePackage(
            source: """
            public enum Rules {
                public static func allowed(_ flag: Bool) -> Bool { flag && true }
                public static func uncovered(_ flag: Bool) -> Bool { flag && false }
            }
            """,
            tests: """
            import Foundation
            import Logic
            import Testing

            @Suite struct LogicTests {
            @Test("waits only during a mutant run")
            func waitsDuringMutation() {
                _ = Rules.allowed(true)
                if ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] != nil {
                    Thread.sleep(forTimeInterval: 4)
                }
            }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var configuration = configuration(for: fixture.root, testName: "waits only during a mutant run", operators: [.logical])
        configuration.parallelism = 1
        configuration.timeouts.mutantSeconds = 1

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        #expect(report.summary.timedOut == 2)
        #expect(report.summary.detected == 1)
        #expect(report.summary.score == 1)
        #expect(report.mutants.filter(\.activated).count == 1)
        #expect(report.integrityWarnings.count == 1)
        #expect(report.integrityWarnings.contains(where: { $0.code == "timeoutWithoutActivation" }))
        #expect(report.qualityGate?.passed == false)
    }

    @Test("runs parallel SwiftPM mutants in isolated scratch directories and retries timeouts")
    func parallelSwiftPMTimeoutRetry() throws {
        let fixture = try makePackage(
            source: """
            public enum Rules {
                public static func left(_ value: Bool) -> Bool { value && true }
                public static func right(_ value: Bool) -> Bool { value || false }
            }
            """,
            tests: """
            import Foundation
            import Logic
            import Testing

            @Test("exercises both logical rules")
            func exercisesRules() {
                #expect(Rules.left(true))
                #expect(!Rules.right(false))
                if ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] != nil {
                    Thread.sleep(forTimeInterval: 2.2)
                }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.deletingLastPathComponent().appendingPathComponent("mutation-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        var configuration = configuration(for: fixture.root, operators: [.logical])
        configuration.parallelism = 2
        configuration.timeouts.mutantSeconds = 2
        configuration.timeouts.retryMultiplier = 2

        let report = try MutationEngine().run(configuration: configuration, outputDirectory: output)
        #expect(report.mutants.count == 2)
        #expect(report.summary.timedOut == 0)
        #expect(report.summary.survived == 2)
        #expect(report.summary.noCoverage == 0)
        #expect(report.integrityWarnings.isEmpty)
        #expect(report.mutants.allSatisfy { $0.activated && $0.status == .survived })
        #expect(report.mutants.allSatisfy { $0.message?.contains("retried in isolation") == true })
    }

    private func configuration(for packageRoot: URL, testName: String? = nil, operators: [MutationOperator]) -> RunConfiguration {
        .init(
            project: .init(kind: .swiftPackage, path: packageRoot.path),
            source: ["Sources/Logic/Rules.swift"],
            tests: testName.map { .init(tests: [$0]) } ?? .init(),
            operators: operators,
            operatorTier: "experimental",
            timeouts: .init(buildSeconds: 60, baselineSeconds: 60, mutantSeconds: 30),
            parallelism: 2
        )
    }

    private func makePackage(source: String, tests: String) throws -> (root: URL, testFile: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MutationEngineFixture-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Sources/Logic", isDirectory: true)
        let testDirectory = root.appendingPathComponent("Tests/LogicTests", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "MutationEngineFixture",
            products: [.library(name: "Logic", targets: ["Logic"])],
            targets: [
                .target(name: "Logic"),
                .testTarget(name: "LogicTests", dependencies: ["Logic"])
            ]
        )
        """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: sourceDirectory.appendingPathComponent("Rules.swift"), atomically: true, encoding: .utf8)
        let testFile = testDirectory.appendingPathComponent("RulesTests.swift")
        try tests.write(to: testFile, atomically: true, encoding: .utf8)
        return (root, testFile)
    }
}
