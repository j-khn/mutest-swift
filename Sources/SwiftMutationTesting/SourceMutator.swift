import Foundation
import SwiftParser
import SwiftSyntax
import MutationTestingSpec

public struct SourceSpan: Codable, Sendable, Hashable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct MutationCandidate: Codable, Sendable, Identifiable {
    public var id: String
    public var operatorID: MutationOperator
    public var source: String
    public var line: Int
    public var column: Int
    public var span: SourceSpan
    public var original: String
    public var replacement: String
    public var usesStatementForm: Bool
    /// Statement wrappers are unsafe in a single-item code block because Swift may infer
    /// the block's value as an implicit return. Those candidates stay on the isolated path.
    public var requiresIsolation: Bool
    public var suppressionReason: String?

    public var record: MutantRecord {
        MutantRecord(id: id, operatorID: operatorID, source: source, line: line, column: column, original: original, replacement: replacement)
    }
}

public struct SwiftMutationGenerator: Sendable {
    public init() {}

    public func generate(
        source: String,
        relativePath: String,
        operators: Set<MutationOperator> = Set(MutationOperator.allCases),
        suppression: SuppressionConfiguration = .init()
    ) -> [MutationCandidate] {
        let tree = Parser.parse(source: source)
        let visitor = CandidateVisitor(source: source, relativePath: relativePath, enabled: operators)
        visitor.walk(tree)
        let suppressions = SuppressionMap(source: source, configuration: suppression)
        return visitor.candidates.map { candidate in
            var value = candidate
            value.suppressionReason = suppressions.reason(forLine: candidate.line)
            return value
        }.sorted { $0.span.start < $1.span.start }
    }

    /// Produces one runtime-switch schema from non-overlapping candidates. Candidates that overlap
    /// are returned separately and must be evaluated using an isolated single-mutant build.
    public func makeSchema(source: String, candidates: [MutationCandidate]) -> (source: String, included: Set<String>, isolated: [MutationCandidate]) {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.span.start == rhs.span.start { return lhs.span.end < rhs.span.end }
            return lhs.span.start < rhs.span.start
        }
        var selected: [MutationCandidate] = []
        var isolated: [MutationCandidate] = []
        var end = -1
        for candidate in sorted {
            if candidate.requiresIsolation {
                isolated.append(candidate)
            } else if candidate.span.start >= end {
                selected.append(candidate)
                end = candidate.span.end
            } else {
                isolated.append(candidate)
            }
        }

        var output = Array(source.utf8)
        for candidate in selected.reversed() {
            let original = String(decoding: output[candidate.span.start..<candidate.span.end], as: UTF8.self)
            let replacement: String
            if candidate.usesStatementForm {
                replacement = "if __SwiftMutationRuntime.shouldRunOriginal(\"\(candidate.id)\") { \(original) }"
            } else {
                replacement = "__SwiftMutationRuntime.evaluate(\"\(candidate.id)\", mutated: (\(candidate.replacement)), original: (\(original)))"
            }
            output.replaceSubrange(candidate.span.start..<candidate.span.end, with: replacement.utf8)
        }
        guard !selected.isEmpty else { return (source, [], isolated) }
        var schema = String(decoding: output, as: UTF8.self)
        if !schema.contains("import Foundation") { schema = "import Foundation\n" + schema }
        schema += "\n\n\(Self.runtimeSupport)\n"
        return (schema, Set(selected.map(\.id)), isolated)
    }

    public func singleMutant(source: String, candidate: MutationCandidate) -> String {
        var bytes = Array(source.utf8)
        let replacement = candidate.usesStatementForm ? "()" : candidate.replacement
        bytes.replaceSubrange(candidate.span.start..<candidate.span.end, with: replacement.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Builds one candidate with its activation instrumentation even when the normal
    /// shared-schema path marked it unsafe to combine with other candidates.
    public func makeIsolatedSchema(source: String, candidate: MutationCandidate) -> String {
        var isolatedCandidate = candidate
        isolatedCandidate.requiresIsolation = false
        return makeSchema(source: source, candidates: [isolatedCandidate]).source
    }

    private static let runtimeSupport = #"""
    private enum __SwiftMutationRuntime {
        static func evaluate<T>(_ id: String, mutated: @autoclosure () -> T, original: @autoclosure () -> T) -> T {
            guard ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] == id else { return original() }
            mark(id)
            return mutated()
        }

        static func shouldRunOriginal(_ id: String) -> Bool {
            guard ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] == id else { return true }
            mark(id)
            return false
        }

        private static func mark(_ id: String) {
            let line = Data((id + "\n").utf8)
            if let path = ProcessInfo.processInfo.environment["SWIFT_MUTATION_ACTIVATION_FILE"] {
                if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                if let handle = FileHandle(forWritingAtPath: path) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                }
            }
            // Keep an ordered marker in the process log as well as the durable file marker.
            // The runner uses the ordering to ensure the failing test came after activation.
            try? FileHandle.standardError.write(contentsOf: Data(("SWIFT_MUTATION_ACTIVATED:" + id + "\n").utf8))
        }
    }
    """#
}

private final class CandidateVisitor: SyntaxVisitor {
    let source: String
    let relativePath: String
    let enabled: Set<MutationOperator>
    var candidates: [MutationCandidate] = []
    private let sourceBytes: [UInt8]

    init(source: String, relativePath: String, enabled: Set<MutationOperator>) {
        self.source = source; self.relativePath = relativePath; self.enabled = enabled
        self.sourceBytes = Array(source.utf8)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard let binary = node.operator.as(BinaryOperatorExprSyntax.self) else { return .visitChildren }
        let op = binary.operator.text
        if enabled.contains(.relational), let replacement = Self.relational[op] {
            add(node, operator: .relational, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
        }
        if enabled.contains(.logical), let replacement = Self.logical[op] {
            add(node, operator: .logical, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
        }
        if enabled.contains(.arithmetic), let replacement = Self.arithmetic[op] {
            add(node, operator: .arithmetic, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
        }
        return .visitChildren
    }

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard enabled.contains(.boolean) else { return .skipChildren }
        let replacement = node.literal.text == "true" ? "false" : "true"
        add(node, operator: .boolean, replacement: replacement)
        return .skipChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        guard enabled.contains(.negateConditional), node.conditions.count == 1,
              case .expression(let condition) = node.conditions.first?.condition else { return .visitChildren }
        let original = text(of: condition)
        add(condition, operator: .negateConditional, replacement: "!(\(original))")
        return .visitChildren
    }

    override func visit(_ node: TernaryExprSyntax) -> SyntaxVisitorContinueKind {
        guard enabled.contains(.swapTernary) else { return .visitChildren }
        let condition = text(of: node.condition)
        let thenValue = text(of: node.thenExpression)
        let elseValue = text(of: node.elseExpression)
        add(node, operator: .swapTernary, replacement: "(\(condition)) ? (\(elseValue)) : (\(thenValue))")
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() {
            if let binary = element.as(BinaryOperatorExprSyntax.self) {
                let op = binary.operator.text
                if enabled.contains(.relational), let replacement = Self.relational[op] {
                    add(node, operator: .relational, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
                }
                if enabled.contains(.logical), let replacement = Self.logical[op] {
                    add(node, operator: .logical, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
                }
                if enabled.contains(.arithmetic), let replacement = Self.arithmetic[op] {
                    add(node, operator: .arithmetic, replacement: replaceOperator(in: node, token: binary.operator, with: replacement))
                }
            }
            if enabled.contains(.swapTernary), let ternary = element.as(UnresolvedTernaryExprSyntax.self), index > 0, index + 1 < elements.count {
                let condition = text(from: elements[0], through: elements[index - 1])
                let thenValue = text(of: ternary.thenExpression)
                let elseValue = text(from: elements[index + 1], through: elements[elements.count - 1])
                let replacement = "(\(condition)) ? (\(elseValue)) : (\(thenValue))"
                add(node, operator: .swapTernary, replacement: replacement)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
        guard enabled.contains(.removeSideEffects), case .expr(let expression) = node.item,
              expression.is(FunctionCallExprSyntax.self) else { return .visitChildren }
        let expressionText = text(of: expression)
        add(node, operator: .removeSideEffects, replacement: "()", original: text(of: node), usesStatementForm: true, requiresIsolation: node.parent?.as(CodeBlockItemListSyntax.self)?.count == 1)
        _ = expressionText
        return .visitChildren
    }

    private static let relational: [String: String] = ["<": ">=", "<=": ">", ">": "<=", ">=": "<", "==": "!=", "!=": "==", "===": "!==", "!==": "==="]
    private static let logical: [String: String] = ["&&": "||", "||": "&&"]
    private static let arithmetic: [String: String] = ["+": "-", "-": "+", "*": "/", "/": "*", "%": "*"]

    private func replaceOperator(in node: SyntaxProtocol, token: TokenSyntax, with replacement: String) -> String {
        let nodeStart = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let tokenStart = token.positionAfterSkippingLeadingTrivia.utf8Offset
        let tokenEnd = token.endPositionBeforeTrailingTrivia.utf8Offset
        let value = text(of: node)
        var bytes = Array(value.utf8)
        let start = tokenStart - nodeStart
        let end = tokenEnd - nodeStart
        guard start >= 0, end <= bytes.count, start < end else { return value }
        bytes.replaceSubrange(start..<end, with: replacement.utf8)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func add(_ node: some SyntaxProtocol, operator operatorID: MutationOperator, replacement: String, original: String? = nil, usesStatementForm: Bool = false, requiresIsolation: Bool = false) {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        guard start >= 0, end <= sourceBytes.count, start < end else { return }
        let originalText = original ?? String(decoding: sourceBytes[start..<end], as: UTF8.self)
        let line = sourceBytes[..<start].reduce(into: 1) { count, byte in if byte == 10 { count += 1 } }
        let lineStart = sourceBytes[..<start].lastIndex(of: 10).map { $0 + 1 } ?? 0
        let column = start - lineStart + 1
        let stableParts = ["1.0.0", relativePath.replacingOccurrences(of: "\\", with: "/"), operatorID.rawValue, String(start), originalText, replacement].joined(separator: "\u{0}")
        let id = SHA256Digest.hash(stableParts)
        candidates.append(.init(id: id, operatorID: operatorID, source: relativePath, line: line, column: column, span: .init(start: start, end: end), original: originalText, replacement: replacement, usesStatementForm: usesStatementForm, requiresIsolation: requiresIsolation, suppressionReason: nil))
    }

    private func text(of node: some SyntaxProtocol) -> String {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        guard start >= 0, start <= end, end <= sourceBytes.count else { return node.description }
        return String(decoding: sourceBytes[start..<end], as: UTF8.self)
    }

    private func text(from first: some SyntaxProtocol, through last: some SyntaxProtocol) -> String {
        let start = first.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = last.endPositionBeforeTrailingTrivia.utf8Offset
        guard start >= 0, start <= end, end <= sourceBytes.count else { return first.description + last.description }
        return String(decoding: sourceBytes[start..<end], as: UTF8.self)
    }
}

private struct SuppressionMap {
    private let reasonsByLine: [Int: String]
    init(source: String, configuration: SuppressionConfiguration) {
        guard configuration.enabled else {
            reasonsByLine = [:]
            return
        }
        let lines = source.components(separatedBy: .newlines)
        var map: [Int: String] = [:]
        for (index, line) in lines.enumerated() where line.contains("swift-mutation-testing:disable") {
            let nextLineDirective = line.contains("swift-mutation-testing:disable-next-line")
            let reason = line.split(separator: ":", maxSplits: 2).last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            let normalizedReason = reason.isEmpty || reason == "disable" || reason == "disable-next-line" ? "suppressed by source directive" : reason
            if configuration.requireReason && normalizedReason == "suppressed by source directive" { continue }
            if nextLineDirective {
                if index + 1 < lines.count { map[index + 2] = normalizedReason }
                continue
            }
            // A declaration suppression applies from its next declaration through the end of that
            // declaration. Brace depth is intentionally conservative; malformed scopes never widen
            // suppression beyond the file or suppress unrelated declarations before the comment.
            guard let declaration = lines.indices.dropFirst(index + 1).first(where: { lines[$0].range(of: #"^\s*(?:public\s+|private\s+|fileprivate\s+|internal\s+|final\s+|static\s+|mutating\s+|override\s+|nonisolated\s+)*(?:func|struct|class|enum|extension|var|let|init|subscript)\b"#, options: .regularExpression) != nil }) else { continue }
            var depth = 0
            var began = false
            var endLine = declaration + 1
            for lineIndex in declaration..<lines.count {
                for character in lines[lineIndex] {
                    if character == "{" { depth += 1; began = true }
                    if character == "}" { depth -= 1 }
                }
                endLine = lineIndex + 1
                if began && depth <= 0 { break }
                if !began { break }
            }
            if declaration + 1 <= endLine {
                for lineNumber in (declaration + 1)...endLine { map[lineNumber] = normalizedReason }
            }
        }
        reasonsByLine = map
    }
    func reason(forLine line: Int) -> String? { reasonsByLine[line] }
}
