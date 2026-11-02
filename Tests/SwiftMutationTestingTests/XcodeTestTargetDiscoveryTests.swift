import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Xcode test target discovery")
struct XcodeTestTargetDiscoveryTests {
    @Test("maps test source files to the Xcode test target that compiles them")
    func mapsSourcesToTestTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testFile = root.appendingPathComponent("Modules/Contacts/Tests/ContactTests.swift")
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = #"""
        {
          archiveVersion = 1;
          objectVersion = 56;
          objects = {
            AAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXProject; mainGroup = BBBBBBBBBBBBBBBBBBBBBBBB; targets = ( DDDDDDDDDDDDDDDDDDDDDDDD, ); };
            BBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXGroup; children = ( CCCCCCCCCCCCCCCCCCCCCCCC, ); sourceTree = "<group>"; };
            CCCCCCCCCCCCCCCCCCCCCCCC = { isa = PBXGroup; path = "Modules/Contacts/Tests"; sourceTree = "<group>"; children = ( EEEEEEEEEEEEEEEEEEEEEEEE, ); };
            EEEEEEEEEEEEEEEEEEEEEEEE = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ContactTests.swift; sourceTree = "<group>"; };
            DDDDDDDDDDDDDDDDDDDDDDDD = { isa = PBXNativeTarget; name = ContactsTests; productType = "com.apple.product-type.bundle.unit-test"; buildPhases = ( FFFFFFFFFFFFFFFFFFFFFFFF, ); };
            FFFFFFFFFFFFFFFFFFFFFFFF = { isa = PBXSourcesBuildPhase; files = ( 111111111111111111111111, ); };
            111111111111111111111111 = { isa = PBXBuildFile; fileRef = EEEEEEEEEEEEEEEEEEEEEEEE; };
          };
          rootObject = AAAAAAAAAAAAAAAAAAAAAAAA;
        }
        """#
        let map = try XcodeTestTargetDiscovery.testTargetBySourceFile(in: project, projectRoot: root)

        #expect(map[testFile.standardizedFileURL.path] == ["ContactsTests"])
    }

    @Test("dependency discovery makes Xcode project target ownership available to selectors")
    func dependencyDiscoveryIncludesXcodeTestTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        let testFile = root.appendingPathComponent("Modules/Contacts/Tests/ContactTests.swift")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = #"""
        { archiveVersion = 1; objectVersion = 56; objects = {
          AAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXProject; mainGroup = BBBBBBBBBBBBBBBBBBBBBBBB; targets = ( DDDDDDDDDDDDDDDDDDDDDDDD, ); };
          BBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXGroup; children = ( CCCCCCCCCCCCCCCCCCCCCCCC, ); sourceTree = "<group>"; };
          CCCCCCCCCCCCCCCCCCCCCCCC = { isa = PBXGroup; path = "Modules/Contacts/Tests"; sourceTree = "<group>"; children = ( EEEEEEEEEEEEEEEEEEEEEEEE, ); };
          EEEEEEEEEEEEEEEEEEEEEEEE = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ContactTests.swift; sourceTree = "<group>"; };
          DDDDDDDDDDDDDDDDDDDDDDDD = { isa = PBXNativeTarget; name = ContactsTests; productType = "com.apple.product-type.bundle.unit-test"; buildPhases = ( FFFFFFFFFFFFFFFFFFFFFFFF, ); };
          FFFFFFFFFFFFFFFFFFFFFFFF = { isa = PBXSourcesBuildPhase; files = ( 111111111111111111111111, ); };
          111111111111111111111111 = { isa = PBXBuildFile; fileRef = EEEEEEEEEEEEEEEEEEEEEEEE; };
        }; rootObject = AAAAAAAAAAAAAAAAAAAAAAAA; }
        """#
        try project.write(to: projectURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let graph = try PackageDependencyResolver.discover(
            projectURL: projectURL,
            projectRoot: root,
            kind: .xcodeProject,
            logs: root.appendingPathComponent("logs"),
            timeout: 5
        )

        #expect(graph.testTargetByFile[testFile.standardizedFileURL.path] == ["ContactsTests"])
    }

    @Test("keeps Xcode target ownership when selected tests also belong to a local package")
    func xcodeTargetTakesPrecedenceOverPackageTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        let packageURL = root.appendingPathComponent("Modules/Contacts", isDirectory: true)
        let testFile = packageURL.appendingPathComponent("Tests/ContactsTests/ContactTests.swift")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: testFile, atomically: true, encoding: .utf8)
        try #"""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Contacts", targets: [
            .target(name: "Contacts"),
            .testTarget(name: "ContactsTests", dependencies: ["Contacts"])
        ])
        """#.write(to: packageURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = #"""
        { archiveVersion = 1; objectVersion = 56; objects = {
          AAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXProject; mainGroup = BBBBBBBBBBBBBBBBBBBBBBBB; targets = ( DDDDDDDDDDDDDDDDDDDDDDDD, ); };
          BBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXGroup; children = ( EEEEEEEEEEEEEEEEEEEEEEEE, ); sourceTree = "<group>"; };
          EEEEEEEEEEEEEEEEEEEEEEEE = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Modules/Contacts/Tests/ContactsTests/ContactTests.swift"; sourceTree = SOURCE_ROOT; };
          DDDDDDDDDDDDDDDDDDDDDDDD = { isa = PBXNativeTarget; name = AppTests; productType = "com.apple.product-type.bundle.unit-test"; buildPhases = ( FFFFFFFFFFFFFFFFFFFFFFFF, ); };
          FFFFFFFFFFFFFFFFFFFFFFFF = { isa = PBXSourcesBuildPhase; files = ( 111111111111111111111111, ); };
          111111111111111111111111 = { isa = PBXBuildFile; fileRef = EEEEEEEEEEEEEEEEEEEEEEEE; };
        }; rootObject = AAAAAAAAAAAAAAAAAAAAAAAA; }
        """#
        try project.write(to: projectURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let graph = try PackageDependencyResolver.discover(
            projectURL: projectURL,
            projectRoot: root,
            kind: .xcodeProject,
            testPackageRoots: [packageURL],
            logs: root.appendingPathComponent("logs"),
            timeout: 10
        )

        #expect(graph.testTargetByFile[testFile.standardizedFileURL.path] == ["AppTests"])
    }

    @Test("workspace discovery combines test-file membership from referenced Xcode projects")
    func workspaceDiscoveryIncludesXcodeTestTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workspace = root.appendingPathComponent("Fixture.xcworkspace", isDirectory: true)
        let projectURL = root.appendingPathComponent("Fixture.xcodeproj", isDirectory: true)
        let testFile = root.appendingPathComponent("Tests/AppTests.swift")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: testFile, atomically: true, encoding: .utf8)
        try #"<Workspace version="1.0"><FileRef location="group:Fixture.xcodeproj"></FileRef></Workspace>"#
            .write(to: workspace.appendingPathComponent("contents.xcworkspacedata"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = #"""
        { archiveVersion = 1; objectVersion = 56; objects = {
          AAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXProject; mainGroup = BBBBBBBBBBBBBBBBBBBBBBBB; targets = ( DDDDDDDDDDDDDDDDDDDDDDDD, ); };
          BBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXGroup; children = ( EEEEEEEEEEEEEEEEEEEEEEEE, ); sourceTree = "<group>"; };
          EEEEEEEEEEEEEEEEEEEEEEEE = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Tests/AppTests.swift; sourceTree = "<group>"; };
          DDDDDDDDDDDDDDDDDDDDDDDD = { isa = PBXNativeTarget; name = AppTests; productType = "com.apple.product-type.bundle.unit-test"; buildPhases = ( FFFFFFFFFFFFFFFFFFFFFFFF, ); };
          FFFFFFFFFFFFFFFFFFFFFFFF = { isa = PBXSourcesBuildPhase; files = ( 111111111111111111111111, ); };
          111111111111111111111111 = { isa = PBXBuildFile; fileRef = EEEEEEEEEEEEEEEEEEEEEEEE; };
        }; rootObject = AAAAAAAAAAAAAAAAAAAAAAAA; }
        """#
        try project.write(to: projectURL.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let graph = try PackageDependencyResolver.discover(
            projectURL: workspace,
            projectRoot: root,
            kind: .xcodeWorkspace,
            logs: root.appendingPathComponent("logs"),
            timeout: 5
        )

        #expect(graph.testTargetByFile[testFile.standardizedFileURL.path] == ["AppTests"])
    }

    @Test("maps synchronized test groups without requiring explicit file references")
    func mapsSynchronizedGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let testFile = root.appendingPathComponent("ShareUI/Tests/ViewTests.swift")
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = #"""
        {
          archiveVersion = 1;
          objectVersion = 60;
          objects = {
            AAAAAAAAAAAAAAAAAAAAAAAA = { isa = PBXProject; mainGroup = BBBBBBBBBBBBBBBBBBBBBBBB; targets = ( DDDDDDDDDDDDDDDDDDDDDDDD, ); };
            BBBBBBBBBBBBBBBBBBBBBBBB = { isa = PBXGroup; children = ( CCCCCCCCCCCCCCCCCCCCCCCC, ); sourceTree = "<group>"; };
            CCCCCCCCCCCCCCCCCCCCCCCC = { isa = PBXFileSystemSynchronizedRootGroup; path = ShareUI; sourceTree = "<group>"; };
            DDDDDDDDDDDDDDDDDDDDDDDD = { isa = PBXNativeTarget; name = ShareUITests; productType = "com.apple.product-type.bundle.unit-test"; fileSystemSynchronizedGroups = ( CCCCCCCCCCCCCCCCCCCCCCCC, ); buildPhases = ( FFFFFFFFFFFFFFFFFFFFFFFF, ); };
            FFFFFFFFFFFFFFFFFFFFFFFF = { isa = PBXSourcesBuildPhase; files = ( ); };
          };
          rootObject = AAAAAAAAAAAAAAAAAAAAAAAA;
        }
        """#
        let map = try XcodeTestTargetDiscovery.testTargetBySourceFile(in: project, projectRoot: root)

        #expect(map[testFile.standardizedFileURL.path] == ["ShareUITests"])
    }
}
