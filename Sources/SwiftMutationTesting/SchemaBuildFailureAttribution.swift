import Foundation

struct SchemaBuildFailure {
    var output: String
    var log: URL
    var timedOut: Bool
}

/// Uses Swift compiler locations to keep one invalid or overly complex mutation from
/// forcing the entire schema to be bisected and rebuilt.
enum SchemaBuildFailureAttribution {
    private static let diagnosticPattern = #"(?m)(?:^|\n)([^\n]+?\.swift):(\d+):\d+: error:"#

    static func implicatedCandidates(
        in output: String,
        candidates: [MutationCandidate],
        sources: [String: String]
    ) -> [MutationCandidate] {
        guard !candidates.isEmpty else { return [] }
        let expression = try? NSRegularExpression(pattern: diagnosticPattern)
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let expression else { return [] }

        var implicated = Set<String>()
        for match in expression.matches(in: output, range: fullRange) {
            guard let pathRange = Range(match.range(at: 1), in: output),
                  let lineRange = Range(match.range(at: 2), in: output),
                  let line = Int(output[lineRange]) else { continue }
            let diagnosticPath = URL(fileURLWithPath: String(output[pathRange])).standardizedFileURL.path
            let matchingSources = Set(candidates.map(\.source).filter { source in
                diagnosticPath == source || diagnosticPath.hasSuffix("/" + source)
            })
            for source in matchingSources {
                let sourceCandidates = candidates.filter { $0.source == source }
                guard let contents = sources[source] else {
                    sourceCandidates.forEach { implicated.insert($0.id) }
                    continue
                }
                // makeSchema prepends a SwiftLint directive and may also prepend Foundation.
                let generatedPrefixLines = contents.contains("import Foundation") ? 1 : 2
                let sourceLine = line - generatedPrefixLines
                let matchingLines = sourceCandidates.filter { candidate in
                    Self.line(at: candidate.span.start, in: contents) <= sourceLine
                        && sourceLine <= Self.line(at: max(candidate.span.start, candidate.span.end - 1), in: contents)
                }
                // Generated helper diagnostics and compiler locations remapped by #sourceLocation
                // may not land inside a mutation span. In that case, isolate only this file.
                (matchingLines.isEmpty ? sourceCandidates : matchingLines).forEach {
                    implicated.insert($0.id)
                }
            }
        }

        return candidates.filter { implicated.contains($0.id) }
    }

    private static func line(at byteOffset: Int, in source: String) -> Int {
        let bytes = source.utf8
        let offset = min(max(byteOffset, 0), bytes.count)
        return bytes.prefix(offset).reduce(into: 1) { line, byte in
            if byte == 0x0A { line += 1 }
        }
    }
}
