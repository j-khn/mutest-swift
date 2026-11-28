import Foundation
import Testing
@testable import SwiftMutationTesting
#if canImport(FoundationXML)
import FoundationXML
#endif

@Suite("Xcode build preparation")
struct XcodeBuildPreparationTests {
    @Test("cache leases are exclusive and incomplete work is discarded")
    func cacheRecovery() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XcodeBuildWorkspace.open(cache: root, key: "compatible")
        let cache = first.directory
        try FileManager.default.createDirectory(at: first.derivedData, withIntermediateDirectories: true)
        let product = first.derivedData.appendingPathComponent("built-product")
        try Data([1]).write(to: product)
        let concurrent = try XcodeBuildWorkspace.open(cache: root, key: "compatible")
        #expect(concurrent.directory != cache)
        concurrent.cleanup()

        try first.markComplete()
        first.cleanup()
        let warm = try XcodeBuildWorkspace.open(cache: root, key: "compatible")
        #expect(warm.directory == cache)
        #expect(FileManager.default.fileExists(atPath: product.path))
        warm.cleanup() // Simulate a run that did not complete.
        let recovered = try XcodeBuildWorkspace.open(cache: root, key: "compatible")
        defer { recovered.cleanup() }
        #expect(recovered.directory == cache)
        #expect(!FileManager.default.fileExists(atPath: product.path))
        let other = try XcodeBuildWorkspace.open(cache: root, key: "different Xcode")
        defer { other.cleanup() }
        #expect(other.directory != cache)
    }

    @Test("warm cache sync detects same-size edits, deletes stale files, and preserves unchanged times")
    func synchronizeSources() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let a = input.appendingPathComponent("A.swift")
        let deleted = input.appendingPathComponent("Delete.swift")
        let unchanged = input.appendingPathComponent("Unchanged.swift")
        try Data("true".utf8).write(to: a)
        try Data().write(to: deleted)
        try Data().write(to: unchanged)

        let cache = root.appendingPathComponent("cache")
        let staged = ProjectSandbox(container: input, root: input, localPackages: [])
        let first = try XcodeBuildWorkspace.open(cache: cache, key: "compatible")
        let original = try first.prepare(staged)
        let persistentUnchanged = original.root.appendingPathComponent("Unchanged.swift")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: persistentUnchanged.path)
        let before = try FileManager.default.attributesOfItem(atPath: persistentUnchanged.path)[.modificationDate] as? Date
        #expect(before == Date(timeIntervalSince1970: 1000))
        try first.markComplete()
        first.cleanup()

        try Data("nil ".utf8).write(to: a)
        try FileManager.default.removeItem(at: deleted)
        let second = try XcodeBuildWorkspace.open(cache: cache, key: "compatible")
        defer { second.cleanup() }
        let updated = try second.prepare(staged)
        #expect(updated.root == original.root)
        #expect(try Data(contentsOf: updated.root.appendingPathComponent("A.swift")) == Data("nil ".utf8))
        #expect(!FileManager.default.fileExists(atPath: updated.root.appendingPathComponent("Delete.swift").path))
        let date = try FileManager.default.attributesOfItem(atPath: persistentUnchanged.path)[.modificationDate] as? Date
        #expect(date == Date(timeIntervalSince1970: 1000))
    }

    @Test("scope removes unrelated test roots and preserves host, variables and coverage")
    func narrowBuildGraph() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectConfiguration(kind: .xcodeProject, path: "Fixture.xcodeproj", scheme: "Fixture")
        let sandbox = ProjectSandbox(container: root, root: root, localPackages: [])
        let schemes = root.appendingPathComponent("Fixture.xcodeproj/xcshareddata/xcschemes")
        try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
        let scheme = schemes.appendingPathComponent("Fixture.xcscheme")
        let plan = root.appendingPathComponent("Unit Plan.xctestplan")
        func reference(_ name: String, extension suffix: String) -> String {
            "<BuildableReference BlueprintName=\"\(name)\" BlueprintIdentifier=\"\(name)\" ReferencedContainer=\"container:Fixture.xcodeproj\" BuildableName=\"\(name).\(suffix)\"/>"
        }
        let xml = """
        <Scheme><BuildAction><BuildActionEntries>
        <BuildActionEntry buildForTesting="YES">\(reference("Host", extension: "app"))</BuildActionEntry>
        <BuildActionEntry buildForTesting="YES">\(reference("Other", extension: "xctest"))</BuildActionEntry>
        </BuildActionEntries></BuildAction><TestAction>
        <TestPlans><TestPlanReference reference="container:Unit Plan.xctestplan" default="YES"/></TestPlans>
        <Testables><TestableReference>\(reference("Other", extension: "xctest"))</TestableReference></Testables>
        <EnvironmentVariables><EnvironmentVariable key="FIXTURE" value="YES" isEnabled="YES"/></EnvironmentVariables>
        </TestAction></Scheme>
        """
        try Data(xml.utf8).write(to: scheme)
        let data = Data("""
        {"defaultOptions":{"codeCoverage":true},"testTargets":[
        {"target":{"name":"Wanted","identifier":"Wanted","containerPath":"container:Fixture.xcodeproj"}},
        {"target":{"name":"Other","identifier":"Other","containerPath":"container:Fixture.xcodeproj"}}]}
        """.utf8)
        try data.write(to: plan)
        #expect(try XcodeTestBuildScope.narrow(project: project, sandbox: sandbox, targets: ["Missing"], testPlan: nil) != nil)
        #expect(try Data(contentsOf: plan) == data)
        #expect(try XcodeTestBuildScope.narrow(project: project, sandbox: sandbox, targets: ["Wanted"], testPlan: "Unit Plan") == nil)
        let document = try XMLDocument(contentsOf: scheme)
        let entries = try document.nodes(forXPath: "/Scheme/BuildAction/BuildActionEntries/BuildActionEntry/@buildForTesting")
        #expect(entries.compactMap(\.stringValue) == ["YES", "NO"])
        #expect(try document.nodes(forXPath: "/Scheme/TestAction/Testables/TestableReference").isEmpty)
        #expect(try document.nodes(forXPath: "/Scheme/TestAction/EnvironmentVariables/EnvironmentVariable").count == 1)
        let filtered = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: plan)) as? [String: Any])
        #expect((filtered["defaultOptions"] as? [String: Bool])?["codeCoverage"] == true)
        let entriesInPlan = try #require(filtered["testTargets"] as? [[String: [String: String]]])
        #expect(entriesInPlan.compactMap { $0["target"]?["name"] } == ["Wanted"])
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
