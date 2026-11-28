import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum XcodeTestBuildScope {
    private struct Target: Hashable {
        var name: String
        var identifier: String
        var container: String

        init?(_ reference: XMLElement) {
            guard let name = reference.attribute(forName: "BlueprintName")?.stringValue,
                  let identifier = reference.attribute(forName: "BlueprintIdentifier")?.stringValue,
                  let container = reference.attribute(forName: "ReferencedContainer")?.stringValue else { return nil }
            self.init(name: name, identifier: identifier, container: container)
        }

        init(name: String, identifier: String, container: String) {
            self.name = name; self.identifier = identifier; self.container = container
        }
    }

    /// Edit only the campaign's copy. Return a reason when metadata cannot be
    /// narrowed safely, so the caller can use the original graph.
    static func narrow(project: ProjectConfiguration, sandbox: ProjectSandbox, targets: Set<String>, testPlan: String?) throws -> String? {
        guard !targets.isEmpty else { return "the full test suite was selected" }
        guard let scheme = project.scheme, !scheme.contains("/"), scheme != ".", scheme != ".." else { return "the scheme name is not a shared file name" }
        let root = sandbox.root
        let schemeURL = root.appendingPathComponent(project.path)
            .appendingPathComponent("xcshareddata/xcschemes")
            .appendingPathComponent(scheme + ".xcscheme")
        guard isSandboxFile(schemeURL, in: sandbox.container),
              let document = try? XMLDocument(contentsOf: schemeURL, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]),
              let schemeElement = document.rootElement(), schemeElement.name == "Scheme",
              let testAction = schemeElement.elements(forName: "TestAction").first
        else { return "the shared scheme could not be read in the sandbox" }

        let references = testAction.elements(forName: "TestPlans").first?.elements(forName: "TestPlanReference") ?? []
        var planOutput: (URL, Data)?
        var planTargets: [Target] = []
        if !references.isEmpty {
            // Keep one plan so Xcode cannot reintroduce other test bundles.
            let chosen = references.filter { reference in
                if let testPlan {
                    guard let path = reference.attribute(forName: "reference")?.stringValue,
                          path.hasPrefix("container:") else { return false }
                    let relativePath = String(path.dropFirst("container:".count))
                    return URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent == testPlan
                }
                return references.count == 1 || reference.attribute(forName: "default")?.stringValue == "YES"
            }
            guard chosen.count == 1, let reference = chosen.first,
                  let path = reference.attribute(forName: "reference")?.stringValue, path.hasPrefix("container:"),
                  !path.dropFirst("container:".count).hasPrefix("/")
            else { return "the effective test plan is ambiguous" }

            let planURL = root.appendingPathComponent(String(path.dropFirst("container:".count))).standardizedFileURL
            guard isSandboxFile(planURL, in: sandbox.container),
                  let data = try? Data(contentsOf: planURL),
                  var plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entries = plan["testTargets"] as? [[String: Any]]
            else { return "the test plan could not be read in the sandbox" }
            var retained: [[String: Any]] = []
            for entry in entries {
                guard let details = entry["target"] as? [String: Any],
                      let name = details["name"] as? String,
                      let identifier = details["identifier"] as? String,
                      let container = details["containerPath"] as? String
                else { return "the test plan includes a target without a complete identity" }
                planTargets.append(.init(name: name, identifier: identifier, container: container))
                if targets.contains(name) { retained.append(entry) }
            }
            let retainedNames = Set(retained.compactMap { ($0["target"] as? [String: Any])?["name"] as? String })
            guard targets.isSubset(of: retainedNames) else { return "some selected targets are absent from the effective test plan" }
            plan["testTargets"] = retained
            planOutput = (planURL, try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys]))
            for other in references where other !== reference { other.detach() }
        } else if testPlan != nil {
            return "the shared scheme does not list the requested test plan"
        }

        let testables = testAction.elements(forName: "Testables").first?.elements(forName: "TestableReference") ?? []
        var knownTargets = planTargets
        for testable in testables {
            guard let reference = testable.elements(forName: "BuildableReference").first,
                  let target = Target(reference) else { return "the scheme includes a test target without a complete identity" }
            knownTargets.append(target)
            if !targets.contains(target.name) { testable.detach() }
        }
        for name in targets {
            guard Set(knownTargets.filter { $0.name == name }).count == 1 else {
                return "the selected test target '\(name)' is missing or ambiguous"
            }
        }

        guard let buildAction = schemeElement.elements(forName: "BuildAction").first,
              buildAction.attribute(forName: "buildImplicitDependencies")?.stringValue == "YES",
              let buildEntries = buildAction.elements(forName: "BuildActionEntries").first
        else { return "the shared scheme does not enable implicit target dependencies" }

        let selected = Set(knownTargets.filter { targets.contains($0.name) })
        let entries = buildEntries.elements(forName: "BuildActionEntry")
        for entry in entries {
            guard let reference = entry.elements(forName: "BuildableReference").first,
                  let target = Target(reference) else { return "a build action has an incomplete target identity" }
            // Keep only the selected test targets as scheme build roots. Their app hosts
            // and product dependencies are still built by Xcode through the target graph.
            entry.attribute(forName: "buildForTesting")?.stringValue = selected.contains(target) ? "YES" : "NO"
        }

        // Preserve the original URL, scheme name, actions and relative paths.
        if let (url, data) = planOutput { try writeIfChanged(data, to: url) }
        try writeIfChanged(document.xmlData, to: schemeURL)
        return nil
    }

    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if try Data(contentsOf: url) != data { try data.write(to: url, options: .atomic) }
    }

    private static func isSandboxFile(_ file: URL, in container: URL) -> Bool {
        let parent = container.resolvingSymlinksInPath().path
        let relative = PackageDependencyResolver.relativePath(file, to: container)
        return !relative.isEmpty && !relative.hasPrefix("/") && file.resolvingSymlinksInPath().path == parent + "/" + relative
            && !relative.split(separator: "/").contains("..")
            && (try? file.resourceValues(forKeys: [.isRegularFileKey])).map { $0.isRegularFile == true } == true
    }
}
