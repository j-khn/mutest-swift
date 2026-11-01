import Foundation

public enum MutationOperator: String, Codable, CaseIterable, Sendable {
    case relational
    case boolean
    case logical
    case arithmetic
    case negateConditional
    case swapTernary
    case removeSideEffects
}

public enum MutantStatus: String, Codable, CaseIterable, Sendable {
    case killed, survived, noCoverage, timeout, unbuildable, suppressed
}

public enum ProjectKind: String, Codable, Sendable {
    case swiftPackage
    case xcodeProject
    case xcodeWorkspace
}

public struct ProjectConfiguration: Codable, Sendable {
    public var kind: ProjectKind
    public var path: String
    public var scheme: String?
    public var testTarget: String?
    public var destination: String?

    public init(kind: ProjectKind = .swiftPackage, path: String = ".", scheme: String? = nil, testTarget: String? = nil, destination: String? = nil) {
        self.kind = kind
        self.path = path
        self.scheme = scheme
        self.testTarget = testTarget
        self.destination = destination
    }
}

public struct TestSelection: Codable, Sendable {
    public var files: [String] = []
    public var suites: [String] = []
    public var tests: [String] = []
    public init(files: [String] = [], suites: [String] = [], tests: [String] = []) {
        self.files = files; self.suites = suites; self.tests = tests
    }
    public var isEmpty: Bool { files.isEmpty && suites.isEmpty && tests.isEmpty }
    enum CodingKeys: String, CodingKey { case files, suites, tests }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decodeIfPresent([String].self, forKey: .files) ?? []
        suites = try values.decodeIfPresent([String].self, forKey: .suites) ?? []
        tests = try values.decodeIfPresent([String].self, forKey: .tests) ?? []
    }
}

public struct Timeouts: Codable, Sendable {
    public var buildSeconds: Int
    public var baselineSeconds: Int
    public var mutantSeconds: Int
    public var parallelRetry: Bool
    public var retryMultiplier: Double
    public init(buildSeconds: Int = 600, baselineSeconds: Int = 300, mutantSeconds: Int = 120, parallelRetry: Bool = true, retryMultiplier: Double = 2) {
        self.buildSeconds = buildSeconds; self.baselineSeconds = baselineSeconds
        self.mutantSeconds = mutantSeconds; self.parallelRetry = parallelRetry; self.retryMultiplier = retryMultiplier
    }
    enum CodingKeys: String, CodingKey { case buildSeconds, baselineSeconds, mutantSeconds, parallelRetry, retryMultiplier }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        buildSeconds = try values.decodeIfPresent(Int.self, forKey: .buildSeconds) ?? 600
        baselineSeconds = try values.decodeIfPresent(Int.self, forKey: .baselineSeconds) ?? 300
        mutantSeconds = try values.decodeIfPresent(Int.self, forKey: .mutantSeconds) ?? 120
        parallelRetry = try values.decodeIfPresent(Bool.self, forKey: .parallelRetry) ?? true
        retryMultiplier = try values.decodeIfPresent(Double.self, forKey: .retryMultiplier) ?? 2
    }
}

public struct QualityGate: Codable, Sendable {
    public var minimumScore: Double?
    public var maximumScoreDrop: Double?
    public var baselineReport: String?
    public var failOnNewSurvivors: Bool
    public var maximumIntegrityWarnings: Int
    public init(minimumScore: Double? = nil, maximumScoreDrop: Double? = nil, baselineReport: String? = nil, failOnNewSurvivors: Bool = false, maximumIntegrityWarnings: Int = 0) {
        self.minimumScore = minimumScore; self.maximumScoreDrop = maximumScoreDrop; self.baselineReport = baselineReport
        self.failOnNewSurvivors = failOnNewSurvivors; self.maximumIntegrityWarnings = maximumIntegrityWarnings
    }
    enum CodingKeys: String, CodingKey { case minimumScore, maximumScoreDrop, baselineReport, failOnNewSurvivors, maximumIntegrityWarnings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimumScore = try values.decodeIfPresent(Double.self, forKey: .minimumScore)
        maximumScoreDrop = try values.decodeIfPresent(Double.self, forKey: .maximumScoreDrop)
        baselineReport = try values.decodeIfPresent(String.self, forKey: .baselineReport)
        failOnNewSurvivors = try values.decodeIfPresent(Bool.self, forKey: .failOnNewSurvivors) ?? false
        maximumIntegrityWarnings = try values.decodeIfPresent(Int.self, forKey: .maximumIntegrityWarnings) ?? 0
    }
}

public struct CacheConfiguration: Codable, Sendable {
    public var enabled: Bool
    /// Directory containing the append-only verdict journal. Relative paths are resolved from the project root.
    public var path: String?
    public init(enabled: Bool = true, path: String? = nil) { self.enabled = enabled; self.path = path }
    enum CodingKeys: String, CodingKey { case enabled, path }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        path = try values.decodeIfPresent(String.self, forKey: .path)
    }
}

public struct SuppressionConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var requireReason: Bool
    public init(enabled: Bool = true, requireReason: Bool = false) { self.enabled = enabled; self.requireReason = requireReason }
    enum CodingKeys: String, CodingKey { case enabled, requireReason }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        requireReason = try values.decodeIfPresent(Bool.self, forKey: .requireReason) ?? false
    }
}

public struct OutputConfiguration: Codable, Sendable {
    public var directory: String?
    public var formats: [String]
    public init(directory: String? = nil, formats: [String] = ["console", "json", "markdown"]) {
        self.directory = directory; self.formats = formats
    }
    enum CodingKeys: String, CodingKey { case directory, formats }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        directory = try values.decodeIfPresent(String.self, forKey: .directory)
        formats = try values.decodeIfPresent([String].self, forKey: .formats) ?? ["console", "json", "markdown"]
    }
}

public struct RunConfiguration: Codable, Sendable {
    public var project: ProjectConfiguration
    public var source: [String]
    public var tests: TestSelection
    public var operators: [MutationOperator]
    public var operatorTier: String
    public var timeouts: Timeouts
    public var parallelism: Int
    public var cache: CacheConfiguration
    public var resume: Bool
    public var suppression: SuppressionConfiguration
    public var output: OutputConfiguration
    public var qualityGate: QualityGate

    public init(project: ProjectConfiguration = .init(), source: [String] = [], tests: TestSelection = .init(), operators: [MutationOperator] = MutationOperator.allCases, operatorTier: String = "experimental", timeouts: Timeouts = .init(), parallelism: Int = 2, cache: CacheConfiguration = .init(), resume: Bool = true, suppression: SuppressionConfiguration = .init(), output: OutputConfiguration = .init(), qualityGate: QualityGate = .init()) {
        self.project = project; self.source = source; self.tests = tests
        self.operators = operators; self.operatorTier = operatorTier; self.timeouts = timeouts
        self.parallelism = parallelism; self.cache = cache; self.resume = resume
        self.suppression = suppression; self.output = output; self.qualityGate = qualityGate
    }

    enum CodingKeys: String, CodingKey { case project, source, tests, operators, operatorTier, timeouts, parallelism, cache, resume, suppression, output, qualityGate }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decode(ProjectConfiguration.self, forKey: .project)
        source = try values.decodeIfPresent([String].self, forKey: .source) ?? []
        tests = try values.decodeIfPresent(TestSelection.self, forKey: .tests) ?? .init()
        operators = try values.decodeIfPresent([MutationOperator].self, forKey: .operators) ?? MutationOperator.allCases
        operatorTier = try values.decodeIfPresent(String.self, forKey: .operatorTier) ?? "experimental"
        timeouts = try values.decodeIfPresent(Timeouts.self, forKey: .timeouts) ?? .init()
        parallelism = try values.decodeIfPresent(Int.self, forKey: .parallelism) ?? 2
        cache = try values.decodeIfPresent(CacheConfiguration.self, forKey: .cache) ?? .init()
        resume = try values.decodeIfPresent(Bool.self, forKey: .resume) ?? true
        suppression = try values.decodeIfPresent(SuppressionConfiguration.self, forKey: .suppression) ?? .init()
        output = try values.decodeIfPresent(OutputConfiguration.self, forKey: .output) ?? .init()
        qualityGate = try values.decodeIfPresent(QualityGate.self, forKey: .qualityGate) ?? .init()
    }
}

public struct MutantRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var operatorID: MutationOperator
    public var source: String
    public var line: Int
    public var column: Int
    public var original: String
    public var replacement: String
    public var status: MutantStatus
    public var activated: Bool
    public var durationSeconds: Double?
    public var message: String?
    public var suppressionReason: String?

    public init(id: String, operatorID: MutationOperator, source: String, line: Int, column: Int = 1, original: String, replacement: String, status: MutantStatus = .unbuildable, activated: Bool = false, durationSeconds: Double? = nil, message: String? = nil, suppressionReason: String? = nil) {
        self.id = id; self.operatorID = operatorID; self.source = source; self.line = line; self.column = column
        self.original = original; self.replacement = replacement; self.status = status
        self.activated = activated; self.durationSeconds = durationSeconds; self.message = message
        self.suppressionReason = suppressionReason
    }

    enum CodingKeys: String, CodingKey {
        case id, source, line, column, original, replacement, status, activated, durationSeconds, message, suppressionReason
        case operatorID = "operator"
    }
}

public struct IntegrityWarning: Codable, Sendable {
    public var code: String
    public var message: String
    public var mutantId: String?
    public init(code: String, message: String, mutantId: String? = nil) { self.code = code; self.message = message; self.mutantId = mutantId }
}

public struct MutationSummary: Codable, Sendable {
    public var generated: Int
    public var killed: Int
    public var survived: Int
    public var noCoverage: Int
    public var timedOut: Int
    public var unbuildable: Int
    public var suppressed: Int
    public var detected: Int
    public var undetected: Int
    public var score: Double?

    public init(records: [MutantRecord]) {
        generated = records.count
        killed = records.filter { $0.status == .killed }.count
        survived = records.filter { $0.status == .survived }.count
        noCoverage = records.filter { $0.status == .noCoverage }.count
        timedOut = records.filter { $0.status == .timeout }.count
        unbuildable = records.filter { $0.status == .unbuildable }.count
        suppressed = records.filter { $0.status == .suppressed }.count
        detected = killed + records.filter { $0.status == .timeout && $0.activated }.count
        undetected = survived + noCoverage
        let denominator = detected + undetected
        score = denominator == 0 ? nil : Double(detected) / Double(denominator)
    }
}

public struct QualityGateResult: Codable, Sendable {
    public var passed: Bool
    public var failures: [String]
}

/// Wall-clock phase durations emitted by native engines for performance analysis.
public struct MutationTimings: Codable, Sendable {
    public var sandboxCopySeconds: Double
    public var testDiscoverySeconds: Double
    public var sourceDiscoverySeconds: Double
    public var inputHashSeconds: Double
    public var baselineSeconds: Double
    public var schemaBuildSeconds: Double
    public var mutantRunSeconds: Double
    public var isolatedBuildSeconds: Double
    public var cleanupSeconds: Double

    public init(sandboxCopySeconds: Double = 0, testDiscoverySeconds: Double = 0, sourceDiscoverySeconds: Double = 0, inputHashSeconds: Double = 0, baselineSeconds: Double = 0, schemaBuildSeconds: Double = 0, mutantRunSeconds: Double = 0, isolatedBuildSeconds: Double = 0, cleanupSeconds: Double = 0) {
        self.sandboxCopySeconds = sandboxCopySeconds
        self.testDiscoverySeconds = testDiscoverySeconds
        self.sourceDiscoverySeconds = sourceDiscoverySeconds
        self.inputHashSeconds = inputHashSeconds
        self.baselineSeconds = baselineSeconds
        self.schemaBuildSeconds = schemaBuildSeconds
        self.mutantRunSeconds = mutantRunSeconds
        self.isolatedBuildSeconds = isolatedBuildSeconds
        self.cleanupSeconds = cleanupSeconds
    }
}

public struct MutationReport: Codable, Sendable {
    public var schemaVersion: String = "1.0.0"
    public var runId: String
    public var engine: EngineIdentity
    public var scope: Scope
    public var summary: MutationSummary
    public var mutants: [MutantRecord]
    public var integrityWarnings: [IntegrityWarning]
    public var qualityGate: QualityGateResult?
    public var timings: MutationTimings?

    public struct EngineIdentity: Codable, Sendable {
        public var name: String; public var version: String; public var tierPolicy: String
        public init(name: String, version: String, tierPolicy: String) { self.name = name; self.version = version; self.tierPolicy = tierPolicy }
    }
    public struct Scope: Codable, Sendable {
        public var sources: [String]; public var tests: [String]; public var allTests: Bool
        public init(sources: [String], tests: [String], allTests: Bool) { self.sources = sources; self.tests = tests; self.allTests = allTests }
    }

    public init(runId: String = UUID().uuidString, engine: EngineIdentity = .init(name: "mutest-swift", version: "0.3.0", tierPolicy: "all operators experimental pending campaign"), scope: Scope, mutants: [MutantRecord], integrityWarnings: [IntegrityWarning] = [], qualityGate: QualityGateResult? = nil, timings: MutationTimings? = nil) {
        self.runId = runId; self.engine = engine; self.scope = scope; self.mutants = mutants
        self.summary = MutationSummary(records: mutants); self.integrityWarnings = integrityWarnings; self.qualityGate = qualityGate; self.timings = timings
    }
}

public enum ContractError: Error, Equatable {
    case noMeasurableMutants
    case invalidConfiguration(String)
}

public enum QualityGateEvaluator {
    public static func evaluate(summary: MutationSummary, policy: QualityGate, integrityWarningCount: Int, baselineScore: Double? = nil, newSurvivors: [String] = [], baselineConfigured: Bool = false, baselineScopeMatches: Bool = true) -> QualityGateResult {
        var failures: [String] = []
        if let minimum = policy.minimumScore {
            if let score = summary.score {
                if score < minimum { failures.append(String(format: "Mutation score %.1f%% is below minimum %.1f%%.", score * 100, minimum * 100)) }
            } else { failures.append("No measurable mutants; minimum score cannot be evaluated.") }
        }
        if let maximumDrop = policy.maximumScoreDrop {
            if !baselineConfigured { failures.append("A baseline report is required to evaluate maximum score drop.") }
            else if !baselineScopeMatches { failures.append("The baseline scope does not match the current source and test selection; score drop cannot be compared.") }
            else if let baselineScore, let score = summary.score {
                if baselineScore - score > maximumDrop {
                    failures.append(String(format: "Mutation score dropped %.1f points; maximum allowed drop is %.1f points.", (baselineScore - score) * 100, maximumDrop * 100))
                }
            } else { failures.append("A score-drop gate cannot be evaluated because the baseline or current run has no measurable score.") }
        }
        if policy.failOnNewSurvivors {
            if !baselineConfigured { failures.append("A baseline report is required to detect new surviving mutants.") }
            else if !newSurvivors.isEmpty { failures.append("New surviving mutants: \(newSurvivors.joined(separator: ", "))") }
        }
        if integrityWarningCount > policy.maximumIntegrityWarnings { failures.append("Integrity warnings (\(integrityWarningCount)) exceed allowed maximum (\(policy.maximumIntegrityWarnings)).") }
        return .init(passed: failures.isEmpty, failures: failures)
    }
}
