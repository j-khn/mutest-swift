import Foundation
import Testing
@testable import SwiftMutationTesting

@Suite("Swift package test-target discovery")
struct PackageDependenciesTests {
    @Test("maps files in each package test target from SwiftPM's manifest output")
    func mapsTestFilesToTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let contactsFile = root.appendingPathComponent("Tests/ContactsTests/ContactTests.swift")
        let uiFile = root.appendingPathComponent("CustomTests/UserPickerTests.swift")
        try FileManager.default.createDirectory(at: contactsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: uiFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "import Testing\n".write(to: contactsFile, atomically: true, encoding: .utf8)
        try "import Testing\n".write(to: uiFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let dump = #"{"targets":[{"name":"ContactsTests","type":"test","path":"Tests/ContactsTests","sources":["Tests/ContactsTests/ContactTests.swift"]},{"name":"UserPickerTests","type":"test","path":"CustomTests","sources":["UserPickerTests.swift"]},{"name":"Library","type":"library","path":"Sources/Library","sources":["Sources/Library/Library.swift"]}]}"#
        let map = try PackageDependencyResolver.testTargetBySourceFile(in: dump, packageRoot: root)

        #expect(map[contactsFile.standardizedFileURL.path] == ["ContactsTests"])
        #expect(map[uiFile.standardizedFileURL.path] == ["UserPickerTests"])
        #expect(map.count == 2)
    }
}
