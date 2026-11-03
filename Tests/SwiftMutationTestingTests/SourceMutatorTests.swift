import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Swift mutation generation")
struct SourceMutatorTests {
    let source = """
    func decide(_ value: Int, _ enabled: Bool) -> Int {
        if value >= 10 && enabled {
            return value + 2
        }
        return enabled ? value : 0
    }
    """

    @Test("generates relational, logical, arithmetic, boolean, conditional, and ternary mutations")
    func generatesCoreOperators() {
        let candidates = SwiftMutationGenerator().generate(source: source, relativePath: "Sources/Rule.swift")
        #expect(candidates.contains { $0.operatorID == .relational })
        #expect(candidates.contains { $0.operatorID == .logical })
        #expect(candidates.contains { $0.operatorID == .arithmetic })
        #expect(candidates.contains { $0.operatorID == .negateConditional })
        #expect(candidates.contains { $0.operatorID == .swapTernary })
    }

    @Test("generates a boolean literal mutation")
    func booleanLiteral() {
        let candidates = SwiftMutationGenerator().generate(source: "func enabled() -> Bool { true }", relativePath: "Sources/Rule.swift")
        #expect(candidates.count == 1)
        #expect(candidates.first?.operatorID == .boolean)
        #expect(candidates.first?.replacement == "false")
    }

    @Test("generates a standalone side effect removal")
    func sideEffect() {
        let candidates = SwiftMutationGenerator().generate(source: "func write() { record(\"value\"); finish() }", relativePath: "Sources/Rule.swift")
        #expect(candidates.contains { $0.operatorID == .removeSideEffects })
    }

    @Test("skips calls that upstream treats as non-mutation candidates")
    func skippedSideEffectCalls() {
        let input = "func write() { print(\"value\"); assert(true); fatalError(\"stop\") }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.removeSideEffects])
        #expect(candidates.isEmpty)
    }

    @Test("keeps safe statement mutations in a shared schema")
    func safeStatementSchema() {
        let input = "func write() { record(\"first\"); record(\"second\") }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.removeSideEffects])
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { !$0.requiresIsolation })
        #expect(schema.included.count == 2)
        #expect(schema.isolated.isEmpty)
    }

    @Test("skips a call that is the implicit return of its function body")
    func implicitReturnStatementSkipped() {
        let input = "func clamp(_ value: Int) -> Int { max(0, value) }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.removeSideEffects])
        #expect(candidates.isEmpty)
    }

    @Test("swaps ternary branches while preserving the complete condition")
    func ternaryCondition() {
        let input = "func price(_ cents: Int) -> Int { cents > 10_000 ? 0 : 799 }"
        let candidate = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift").first { $0.operatorID == .swapTernary }
        #expect(candidate?.replacement.contains("cents > 10_000") == true)
        #expect(candidate?.replacement.contains("? (799) : (0)") == true)
    }

    @Test("schema keeps original behavior unless the mutant ID is active")
    func schemaHasActivationSwitch() {
        let candidates = SwiftMutationGenerator().generate(source: "func enabled() -> Bool { true }", relativePath: "Sources/Rule.swift")
        let schema = SwiftMutationGenerator().makeSchema(source: "func enabled() -> Bool { true }", candidates: candidates)
        #expect(schema.included.count == 1)
        #expect(schema.source.contains("SWIFT_MUTATION_ID"))
        #expect(schema.source.contains("SWIFT_MUTATION_ACTIVATION_FILE"))
        #expect(schema.source.hasPrefix("// swiftlint:disable line_length\n"))
        #expect(schema.source.contains("public enum MutestRuntime"))
        #expect(schema.source.contains("handle.write(line)"))
        #expect(!schema.source.contains("write(contentsOf:"))
        #expect(schema.source.contains("handle.closeFile()"))
        #expect(schema.source.contains("handle.seekToEndOfFile()"))
    }

    @Test("inactive schema keeps the original result and records an active mutant once")
    func schemaRuntimeBehavior() throws {
        let input = "public func enabled() -> Bool { true }"
        let candidate = try #require(SwiftMutationGenerator().generate(
            source: input, relativePath: "Sources/Rule.swift", operators: [.boolean]).first)
        let generated = SwiftMutationGenerator().makeSchema(source: input, candidates: [candidate]).source
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mutest-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("schema-test")
        let marker = directory.appendingPathComponent("activation.txt")
        try (generated + "\nprint(enabled())\nprint(enabled())\n").write(to: file, atomically: true, encoding: .utf8)

        func launch(_ path: String, _ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, text)
        }

        let compile = try launch("/usr/bin/env", ["swiftc", file.path, "-o", executable.path])
        #expect(compile.0 == 0, "Swift compiler rejected generated schema: \(compile.1)")
        guard compile.0 == 0 else { return }
        let inactive = try launch(executable.path, [])
        #expect(inactive.0 == 0 && inactive.1 == "true\ntrue\n")
        let active = try launch(executable.path, [], environment: [
            "SWIFT_MUTATION_ID": candidate.id,
            "SWIFT_MUTATION_ACTIVATION_FILE": marker.path
        ])
        #expect(active.0 == 0 && active.1.contains("false\nfalse\n"))
        let markers = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        #expect(markers == [Substring(candidate.id)])
        #expect(active.1.components(separatedBy: "SWIFT_MUTATION_ACTIVATED:").count == 2)
    }

    @Test("groups overlapping operator mutations into one runtime schema")
    func overlappingOperatorsShareSchema() {
        let input = "func fee(_ amount: Int, _ rate: Int) -> Int { (amount * rate + 5_000) / 10_000 }"
        let candidates = SwiftMutationGenerator().generate(
            source: input,
            relativePath: "Sources/Rule.swift",
            operators: [.arithmetic]
        )
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)

        #expect(candidates.count > 1)
        #expect(schema.included == Set(candidates.map(\.id)))
        #expect(schema.isolated.isEmpty)
        #expect(schema.source.contains("MutestRuntime") && schema.source.contains(".isActive"))
        #expect(!schema.source.contains(".select") && !schema.source.contains(".evaluate"))
        #expect(!schema.source.contains("() -> T"))
    }

    @Test("generates public activation helpers for mutated default arguments")
    func defaultArgumentSchemaAccess() {
        let input = "public func enabled(_ value: Bool = true) -> Bool { value }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.boolean])
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)
        #expect(schema.included.count == 1)
        #expect(schema.source.contains("public enum MutestRuntime"))
        #expect(schema.source.contains("public static func isActive"))
    }

    @Test("keeps async and implicit-self expressions inline instead of moving them into closures")
    func asyncAndInstanceExpressionsStayInline() {
        let input = """
        @MainActor
        final class SocketState {
            var connected = true
            func isReady() async -> Bool {
                await ping() && connected
            }
            func ping() async -> Bool { true }
        }
        """
        let candidates = SwiftMutationGenerator().generate(
            source: input,
            relativePath: "Sources/SocketState.swift",
            operators: [.boolean, .logical]
        )
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)

        #expect(schema.included.count == candidates.count)
        #expect(schema.isolated.isEmpty)
        #expect(schema.source.contains("await ping()"))
        #expect(schema.source.contains("connected"))
        #expect(schema.source.contains(".isActive"))
        #expect(!schema.source.contains(".evaluate") && !schema.source.contains(".select"))
        #expect(!schema.source.contains("mutations: ["))
    }

    @Test("isolates candidates inside macro expansion arguments")
    func macroExpansionArgumentsUseIsolatedPath() {
        let input = "let query = #Predicate<Int> { $0 > 0 }"
        let candidates = SwiftMutationGenerator().generate(
            source: input,
            relativePath: "Sources/Query.swift",
            operators: [.relational]
        )
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)

        #expect(!candidates.isEmpty)
        #expect(schema.included.isEmpty)
        #expect(schema.isolated.map(\.id) == candidates.map(\.id))
    }

    @Test("compiler diagnostics narrow schema failure to the matching source line")
    func schemaFailureAttribution() {
        let input = """
        func enabled() -> Bool { true }
        func compare(_ value: Int) -> Bool { value > 0 }
        """
        let candidates = SwiftMutationGenerator().generate(
            source: input,
            relativePath: "Sources/Rule.swift",
            operators: [.boolean, .relational]
        )
        let implicated = SchemaBuildFailureAttribution.implicatedCandidates(
            in: "/tmp/build/Sources/Rule.swift:4:42: error: compiler diagnostic",
            candidates: candidates,
            sources: ["Sources/Rule.swift": input]
        )

        #expect(!implicated.isEmpty)
        #expect(implicated.allSatisfy { $0.line == 2 })
        #expect(implicated.count < candidates.count)
    }

    @Test("SHA-256 output is stable and standard")
    func digest() {
        #expect(SHA256Digest.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256Digest.hash(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("suppression-next-line is attached to the next source line")
    func suppression() {
        let input = """
        // swift-mutation-testing:disable-next-line reason: covered elsewhere
        let hidden = true
        let visible = false
        """
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift")
        #expect(candidates.count == 2)
        #expect(candidates.first(where: { $0.line == 2 })?.suppressionReason != nil)
        #expect(candidates.first(where: { $0.line == 3 })?.suppressionReason == nil)
    }

    @Test("declaration suppression covers mutations inside that declaration only")
    func declarationSuppression() {
        let input = """
        // swift-mutation-testing:disable reason: legacy behavior
        func legacyValue() -> Bool { true }
        func currentValue() -> Bool { false }
        """
        let candidates = SwiftMutationGenerator().generate(
            source: input,
            relativePath: "Sources/Rule.swift",
            operators: [.boolean]
        )
        #expect(candidates.count == 2)
        #expect(candidates.first(where: { $0.line == 2 })?.suppressionReason == "legacy behavior")
        #expect(candidates.first(where: { $0.line == 3 })?.suppressionReason == nil)
    }

    @Test("suppression configuration can disable rules and require a reason")
    func suppressionConfiguration() {
        let source = """
        // swift-mutation-testing:disable-next-line
        let uncovered = true
        // swift-mutation-testing:disable-next-line reason: documented exception
        let documented = false
        """
        let generator = SwiftMutationGenerator()
        let candidates = generator.generate(source: source, relativePath: "Example.swift", operators: [.boolean])
        #expect(candidates.first(where: { $0.line == 2 })?.suppressionReason != nil)
        let withoutReason = generator.generate(
            source: source,
            relativePath: "Example.swift",
            operators: [.boolean],
            suppression: .init(requireReason: true)
        )
        #expect(withoutReason.first(where: { $0.line == 2 })?.suppressionReason == nil)
        #expect(withoutReason.first(where: { $0.line == 4 })?.suppressionReason != nil)
        let disabled = generator.generate(
            source: source,
            relativePath: "Example.swift",
            operators: [.boolean],
            suppression: .init(enabled: false)
        )
        #expect(disabled.allSatisfy { $0.suppressionReason == nil })
    }
}
