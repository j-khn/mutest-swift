import Foundation

enum XcodeTestResultReader {
    static func readCases(from resultBundle: URL, relativeTo projectRoot: URL) throws -> [MutationTestCaseDetails]? {
        guard FileManager.default.fileExists(atPath: resultBundle.path) else { return nil }

        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mutest-xcresult-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputFile) }

        let command = CommandSpec(
            executable: "/usr/bin/xcrun",
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path, "--compact"],
            workingDirectory: resultBundle.deletingLastPathComponent(),
            timeout: 30,
            outputFile: outputFile
        )

        let result: CommandResult
        do {
            result = try ProcessRunner().run(command)
        } catch ProcessRunnerError.cancelled {
            throw ProcessRunnerError.cancelled
        } catch {
            return nil
        }
        guard !result.timedOut, result.exitCode == 0,
              let json = jsonObject(in: result.output),
              let root = json as? [String: Any],
              let topLevelNodes = root["testNodes"] as? [[String: Any]] else { return nil }

        var testCases: [MutationTestCaseDetails] = []
        var testCaseRuns: [MutationTestCaseDetails] = []
        for node in topLevelNodes { collect(node, inheritedLocation: (nil, nil), projectRoot: projectRoot, cases: &testCases, runs: &testCaseRuns) }

        let selected = testCaseRuns.isEmpty ? testCases : testCaseRuns
        var unique: [String: MutationTestCaseDetails] = [:]
        for testCase in selected {
            unique[testCase.identifier] = testCase
        }
        return unique.values.sorted {
            if $0.testFile != $1.testFile { return ($0.testFile ?? "") < ($1.testFile ?? "") }
            if $0.lineNumber != $1.lineNumber { return ($0.lineNumber ?? 0) < ($1.lineNumber ?? 0) }
            return $0.name < $1.name
        }
    }

    private static func collect(
        _ node: [String: Any],
        inheritedLocation: (file: String?, line: Int?),
        projectRoot: URL,
        cases: inout [MutationTestCaseDetails],
        runs: inout [MutationTestCaseDetails]
    ) {
        let location = node["sourceLocation"] as? [String: Any]
        let rawFile = location?["filePath"] as? String ?? inheritedLocation.file
        let relativeFile = rawFile.map { relativePath($0, projectRoot: projectRoot) }
        let line = (location?["lineNumber"] as? NSNumber)?.intValue ?? inheritedLocation.line
        let nodeType = node["nodeType"] as? String
        let result = node["result"] as? String

        if result != "Skipped", nodeType == "Test Case" || nodeType == "Test Case Run" {
            let name = node["name"] as? String ?? "Unnamed test"
            let identifier = (node["nodeIdentifier"] as? String)
                ?? (node["nodeIdentifierURL"] as? String)
                ?? name
            let testCase = MutationTestCaseDetails(
                identifier: identifier,
                name: name,
                testFile: relativeFile,
                lineNumber: line,
                result: result
            )
            if nodeType == "Test Case Run" { runs.append(testCase) }
            else { cases.append(testCase) }
        }

        for child in node["children"] as? [[String: Any]] ?? [] {
            collect(child, inheritedLocation: (relativeFile, line), projectRoot: projectRoot, cases: &cases, runs: &runs)
        }
    }

    private static func relativePath(_ path: String, projectRoot: URL) -> String {
        let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let rootPath = projectRoot.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") { return String(filePath.dropFirst(rootPath.count + 1)) }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func jsonObject(in output: String) -> Any? {
        guard let firstBrace = output.firstIndex(of: "{"), let lastBrace = output.lastIndex(of: "}"), firstBrace <= lastBrace else { return nil }
        let json = String(output[firstBrace...lastBrace])
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
