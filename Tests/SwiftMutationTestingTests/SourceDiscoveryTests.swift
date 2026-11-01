import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Source discovery")
struct SourceDiscoveryTests {
    private func fixture(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Source discovery \(UUID().uuidString)")
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "public func total(_ value: Int) -> Int { value + 1 }".write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func paths(_ files: [URL], in root: URL) -> [String] {
        files.map { String($0.path.dropFirst(root.path.count + 1)) }.sorted()
    }

    @Test("old local mutation sandboxes never become Xcode mutation sources")
    func staleSandboxRegression() throws {
        let expected = [
            "App/MutationTestApp.swift",
            "Modules/CheckoutCustomer/Sources/CheckoutCustomer/LoyaltyPointsCalculator.swift",
            "Modules/CheckoutDomain/Sources/CheckoutDomain/CheckoutCalculator.swift",
            "Modules/CheckoutInventory/Sources/CheckoutInventory/InventoryPolicy.swift",
            "Modules/CheckoutShipping/Sources/CheckoutShipping/ShippingCalculator.swift"
        ]
        let manifests = ["CheckoutCustomer", "CheckoutDomain", "CheckoutInventory", "CheckoutShipping"].map { "Modules/\($0)/Package.swift" }
        let stale = (expected + manifests).map { ".swift-mutation-testing/sandboxes/1B9BAA73/\($0)" }
            + [".swift-mutation-testing/all/CheckoutShipping/sandboxes/old/Sources/CheckoutShipping/ShippingCalculator.swift"]
        let root = try fixture(expected + manifests + stale + ["AppTests/CheckoutTests.swift"])
        defer { try? FileManager.default.removeItem(at: root) }

        for kind in [ProjectKind.xcodeProject, .xcodeWorkspace] {
            let files = try MutationEngine().discoverSources(root: root, requested: [], kind: kind)
            #expect(paths(files, in: root) == expected.sorted())
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(stale[0]).path))
    }

    @Test("broad source selectors exclude build output, tests, and package manifests")
    func folderBoundaries() throws {
        let source = "Modules/Feature/Sources/Rules.swift"
        let artifacts = [".build", ".build-xcode", ".git", ".swiftpm", ".swift-mutation-testing", "DerivedData"].flatMap {
            ["\($0)/Generated.swift", "Modules/Feature/\($0)/Generated.swift"]
        }
        let root = try fixture([source, "Package.swift", "Modules/Feature/Package@swift-6.0.swift",
                                "AppTests/RulesTests.swift", "Modules/Feature/Tests/Rules.swift"] + artifacts)
        defer { try? FileManager.default.removeItem(at: root) }

        for selected in [[], ["."], ["Modules"]] {
            let files = try MutationEngine().discoverSources(root: root, requested: selected, kind: .xcodeProject)
            #expect(paths(files, in: root) == [source])
        }
        #expect(throws: MutationEngineError.self) {
            try MutationEngine().discoverSources(root: root, requested: [artifacts[0]], kind: .xcodeProject)
        }
        let selected = try MutationEngine().discoverSources(root: root, requested: [source], kind: .xcodeProject)
        #expect(paths(selected, in: root) == [source])
    }

    @Test("custom report and cache folders are excluded from source discovery")
    func configuredOutputFolders() throws {
        let root = try fixture(["App/Rules.swift", "reports/sandboxes/old/Rules.swift", "cache/checkouts/Rules.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let excluded = [root.appendingPathComponent("reports"), root.appendingPathComponent("cache")]
        for selected in [[], ["."]] {
            let files = try MutationEngine().discoverSources(root: root, requested: selected, kind: .xcodeProject, excluding: excluded)
            #expect(paths(files, in: root) == ["App/Rules.swift"])
        }
    }

    @Test("Swift packages retain the default Sources scope and accept explicit source folders")
    func packageScope() throws {
        let root = try fixture(["Package.swift", "Sources/Logic/Rules.swift", "Sources/.build/Generated.swift",
                                "Tests/LogicTests.swift", "FeatureCode/Extra.swift"])
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = try MutationEngine().discoverSources(root: root, requested: [], kind: .swiftPackage)
        #expect(paths(defaults, in: root) == ["Sources/Logic/Rules.swift"])
        let explicit = try MutationEngine().discoverSources(root: root, requested: ["FeatureCode"], kind: .swiftPackage)
        #expect(paths(explicit, in: root) == ["FeatureCode/Extra.swift"])
    }
}
