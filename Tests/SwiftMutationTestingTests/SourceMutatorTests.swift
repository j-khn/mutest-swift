import Foundation
import Testing
@testable import SwiftMutationTesting
import MutationTestingSpec

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
        let candidates = SwiftMutationGenerator().generate(source: "func write() { print(\"value\") }", relativePath: "Sources/Rule.swift")
        #expect(candidates.contains { $0.operatorID == .removeSideEffects })
    }

    @Test("keeps safe statement mutations in a shared schema")
    func safeStatementSchema() {
        let input = "func write() { print(\"first\"); print(\"second\") }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.removeSideEffects])
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { !$0.requiresIsolation })
        #expect(schema.included.count == 2)
        #expect(schema.isolated.isEmpty)
    }

    @Test("isolates a statement mutation that occupies an implicit-return body")
    func implicitReturnStatementIsolation() throws {
        let input = "func clamp(_ value: Int) -> Int { max(0, value) }"
        let candidates = SwiftMutationGenerator().generate(source: input, relativePath: "Sources/Rule.swift", operators: [.removeSideEffects])
        let schema = SwiftMutationGenerator().makeSchema(source: input, candidates: candidates)
        #expect(candidates.count == 1)
        #expect(candidates.first?.requiresIsolation == true)
        #expect(schema.included.isEmpty)
        #expect(schema.isolated.count == 1)
        let isolatedSchema = SwiftMutationGenerator().makeIsolatedSchema(source: input, candidate: try #require(candidates.first))
        #expect(isolatedSchema.contains("shouldRunOriginal"))
        #expect(isolatedSchema.contains("SWIFT_MUTATION_ACTIVATION_FILE"))
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
