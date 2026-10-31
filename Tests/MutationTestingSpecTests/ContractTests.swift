import Foundation
import Testing
@testable import SwiftMutationTesting
import MutationTestingSpec

@Suite("Shared mutation contract")
struct ContractTests {
    @Test("decodes shared configuration defaults and optional cache/report controls")
    func configurationDecoding() throws {
        let data = Data("""
        {
          "specVersion": "1.0.0",
          "project": {"kind": "swiftPackage", "path": "."},
          "cache": {"enabled": false},
          "suppression": {"enabled": true, "requireReason": true},
          "output": {"directory": "reports", "formats": ["json"]}
        }
        """.utf8)
        let config = try JSONDecoder().decode(RunConfiguration.self, from: data)
        #expect(config.parallelism == 2)
        #expect(config.timeouts.buildSeconds == 600)
        #expect(!config.cache.enabled)
        #expect(config.suppression.requireReason)
        #expect(config.output.directory == "reports")
        #expect(config.output.formats == ["json"])
    }

    @Test("counts killed and activated timeouts as detected")
    func detectedScore() {
        let records = [
            MutantRecord(id: "k", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .killed, activated: true),
            MutantRecord(id: "t", operatorID: .logical, source: "A.swift", line: 2, original: "&&", replacement: "||", status: .timeout, activated: true),
            MutantRecord(id: "s", operatorID: .arithmetic, source: "A.swift", line: 3, original: "+", replacement: "-", status: .survived, activated: true),
            MutantRecord(id: "n", operatorID: .boolean, source: "A.swift", line: 4, original: "true", replacement: "false", status: .noCoverage, activated: false),
            MutantRecord(id: "u", operatorID: .relational, source: "A.swift", line: 5, original: ">", replacement: "<=", status: .unbuildable, activated: false),
            MutantRecord(id: "p", operatorID: .boolean, source: "A.swift", line: 6, original: "false", replacement: "true", status: .suppressed, activated: false)
        ]
        let summary = MutationSummary(records: records)
        #expect(summary.detected == 2)
        #expect(summary.undetected == 2)
        #expect(summary.score == 0.5)
        #expect(summary.unbuildable == 1)
        #expect(summary.suppressed == 1)
    }

    @Test("excludes timeouts without verified activation from the score")
    func unactivatedTimeoutScore() {
        let summary = MutationSummary(records: [
            MutantRecord(id: "k", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .killed, activated: true),
            MutantRecord(id: "t", operatorID: .logical, source: "A.swift", line: 2, original: "&&", replacement: "||", status: .timeout, activated: false)
        ])
        #expect(summary.timedOut == 1)
        #expect(summary.detected == 1)
        #expect(summary.undetected == 0)
        #expect(summary.score == 1)
    }

    @Test("returns no score when there are no measurable mutants")
    func emptyScore() {
        let record = MutantRecord(id: "x", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .unbuildable)
        #expect(MutationSummary(records: [record]).score == nil)
    }

    @Test("evaluates minimum score and integrity warning gates")
    func qualityGate() {
        let summary = MutationSummary(records: [MutantRecord(id: "x", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .survived, activated: true)])
        let gate = QualityGateEvaluator.evaluate(summary: summary, policy: .init(minimumScore: 0.8), integrityWarningCount: 1)
        #expect(!gate.passed)
        #expect(gate.failures.count == 2)
    }

    @Test("passes score-drop gate when current score stays within the configured limit")
    func scoreDropPassesWithinLimit() {
        let summary = MutationSummary(records: [
            MutantRecord(id: "k", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .killed, activated: true),
            MutantRecord(id: "s", operatorID: .boolean, source: "A.swift", line: 2, original: "true", replacement: "false", status: .survived, activated: true)
        ])
        let result = QualityGateEvaluator.evaluate(
            summary: summary,
            policy: .init(maximumScoreDrop: 0.2),
            integrityWarningCount: 0,
            baselineScore: 0.6,
            baselineConfigured: true
        )
        #expect(result.passed)
        #expect(result.failures.isEmpty)
    }

    @Test("rejects score-drop comparisons across different scopes")
    func scoreDropScopeMismatch() {
        let summary = MutationSummary(records: [
            MutantRecord(id: "k", operatorID: .boolean, source: "A.swift", line: 1, original: "true", replacement: "false", status: .killed, activated: true),
            MutantRecord(id: "s", operatorID: .boolean, source: "A.swift", line: 2, original: "true", replacement: "false", status: .survived, activated: true)
        ])
        let result = QualityGateEvaluator.evaluate(
            summary: summary,
            policy: .init(maximumScoreDrop: 0.2),
            integrityWarningCount: 0,
            baselineScore: 0.8,
            baselineConfigured: true,
            baselineScopeMatches: false
        )
        #expect(!result.passed)
        #expect(result.failures.first?.contains("scope does not match") == true)
    }
}
