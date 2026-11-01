#!/usr/bin/env python3
"""Real simulator acceptance checks and sequential 1/2-worker benchmarks. Run on CI."""
import argparse
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time


def simulators():
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    return {d["udid"]: d for devices in data["devices"].values() for d in devices}


def verdicts(report):
    return {m["id"]: (m["status"], m["activated"]) for m in report["mutants"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--app-root", type=Path, required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--skip-fixtures", action="store_true")
    parser.add_argument("--extra-fixtures-only", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = {"checks": [], "benchmarks": [], "error": None}
    initial = simulators()

    def clean_check():
        after = simulators()
        leaked = [d for key, d in after.items() if key not in initial and d["name"].startswith("mutest-")]
        assert not leaked, f"Owned simulators leaked: {leaked}"
        template_id = next((part[3:] for part in args.destination.split(",") if part.startswith("id=")), None)
        if template_id:
            assert template_id in after, "The original simulator was deleted"
            assert after[template_id]["state"] == initial[template_id]["state"], "The original simulator state changed"

    def command(project, scheme, target, workers, output, source, extra=(), operators=None):
        cmd = [str(args.tool), "run", "--project", str(project), "--project-kind",
               "xcode-workspace" if project.suffix == ".xcworkspace" else "xcode-project",
               "--scheme", scheme, "--test-target", target, "--destination", args.destination,
               "--parallelism", str(workers), "--source", source, "--operator-tier", "experimental",
               "--no-cache", "--no-resume", "--output", str(output),
               "--xcodebuild-arg", "ARCHS=arm64", "--xcodebuild-arg", "ONLY_ACTIVE_ARCH=YES",
               "--xcodebuild-arg", "CODE_SIGNING_ALLOWED=NO"]
        if operators:
            cmd += ["--operators", operators]
        return cmd + list(extra)

    def campaign(name, project, scheme, target, workers, source, extra=(), operators=None):
        output = args.output / name
        output.mkdir(parents=True, exist_ok=True)
        cmd = command(project, scheme, target, workers, output, source, extra, operators)
        print(f"\n::group::{name}", flush=True)
        started = time.monotonic()
        with (output / "cli.log").open("w+") as log:
            process = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
            offset = 0
            try:
                while process.poll() is None:
                    time.sleep(1)
                    with (output / "cli.log").open() as reader:
                        reader.seek(offset)
                        text = reader.read()
                        offset = reader.tell()
                        print(text, end="", flush=True)
                    if time.monotonic() - started > 1800:
                        raise TimeoutError(f"{name} exceeded 30 minutes")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=180)
                with (output / "cli.log").open() as reader:
                    reader.seek(offset)
                    print(reader.read(), end="", flush=True)
                clean_check()
        print("::endgroup::", flush=True)
        assert process.returncode == 0, f"{name} exited {process.returncode}; see {output / 'cli.log'}"
        report = json.loads((output / "report.json").read_text())
        assert not report["integrityWarnings"], report["integrityWarnings"]
        assert report["execution"]["activeWorkerCount"] == min(workers, report["summary"]["generated"])
        assert report["execution"]["baselineRunCount"] >= report["execution"]["activeWorkerCount"]
        assert report["execution"]["baselineTestCount"] > 0
        results["checks"].append({"name": name, "mutants": report["summary"]["generated"], "testsPerWorker": report["execution"]["baselineTestCount"], "seconds": report["execution"]["totalDurationSeconds"]})
        return report

    try:
        if not args.skip_fixtures:
            with tempfile.TemporaryDirectory(prefix="mutest-xcode-acceptance-") as temporary:
                fixture = Path(temporary) / "Fixture Project with spaces"
                shutil.copytree(args.engine / "Fixtures/XcodeApp", fixture)
                project = fixture / "MutationFixture.xcodeproj"
                source = "Sources/CheckoutRule.swift"
                if not args.extra_fixtures_only:
                    serial = campaign("fixture-project-serial", project, "MutationFixture", "MutationFixtureTests", 1, source, operators="relational,logical")
                    parallel = campaign("fixture-project-parallel", project, "MutationFixture", "MutationFixtureTests", 2, source, operators="relational,logical")
                    assert verdicts(serial) == verdicts(parallel), "Fixture serial/parallel verdict mismatch"
                    assert serial["scope"] == parallel["scope"]
                    baseline = "\n".join(p.read_text() for p in (args.output / "fixture-project-parallel/logs").glob("baseline-worker-*.log"))
                    assert "CheckoutRuleTests" in baseline and "Test run with" in baseline, "Both frameworks must run"
                    workspace = fixture / "Fixture.xcworkspace"
                    workspace.mkdir()
                    (workspace / "contents.xcworkspacedata").write_text('<Workspace version="1.0"><FileRef location="group:MutationFixture.xcodeproj"/></Workspace>')
                    selected = campaign("fixture-workspace-custom-parameterized", workspace, "MutationFixture", "MutationFixtureTests", 2, source,
                                        ("--test", "evaluates supported weight boundaries"), "logical")
                    assert not selected["scope"]["allTests"] and len(selected["scope"]["tests"]) == 1
                    assert selected["execution"]["baselineTestCount"] == 1
                    legacy = campaign("fixture-project-test-file", project, "MutationFixture", "MutationFixtureTests", 2, source,
                                      ("--test-file", "Tests/CheckoutRuleTests.swift"), "logical")
                    assert legacy["execution"]["baselineTestCount"] == 2
                isolated_fixture = Path(temporary) / "Isolated workers"
                shutil.copytree(fixture, isolated_fixture)
                rule = isolated_fixture / source
                prefix, suffix = rule.read_text().rsplit("}", 1)
                rule.write_text(prefix + 'public static func left() { print("left") }\npublic static func right() { print("right") }\n}' + suffix)
                tests = isolated_fixture / "Tests/CheckoutRuleTests.swift"
                tests.write_text(tests.read_text().replace("final class CheckoutRuleTests: XCTestCase {", "final class CheckoutRuleTests: XCTestCase {\nfunc testSideEffects() { CheckoutRule.left(); CheckoutRule.right() }"))
                isolated = campaign("fixture-isolated-workers", isolated_fixture / "MutationFixture.xcodeproj", "MutationFixture", "MutationFixtureTests", 2, source, operators="removeSideEffects")
                assert isolated["summary"]["survived"] == 2 and isolated["summary"]["generated"] == 2
                assert all(m["activated"] for m in isolated["mutants"])
                assert isolated["timings"]["isolatedBuildSeconds"] > 0

                narrowed_fixture = Path(temporary) / "Narrowed schema"
                shutil.copytree(fixture, narrowed_fixture)
                rule = narrowed_fixture / source
                rule.write_text('''public enum CheckoutRule {
                    public static func total(cents: Int, member: Bool, couponPercent: Int) -> Int { couponPercent > 100 ? 0 : 8900 }
                    public static func canUseExpress(weightGrams: Int, destinationCode: String) -> Bool { weightGrams > 0 && weightGrams <= 25000 && !destinationCode.isEmpty }
                    public static func sum(_ left: Int, _ right: Int) -> Int { left + right }
                    public static func join(_ left: String, _ right: String) -> String { left + right }
                }''')
                tests = narrowed_fixture / "Tests/CheckoutRuleTests.swift"
                tests.write_text(tests.read_text().replace("final class CheckoutRuleTests: XCTestCase {", 'final class CheckoutRuleTests: XCTestCase {\nfunc testFallback() { XCTAssertEqual(CheckoutRule.sum(2, 2), 4); XCTAssertEqual(CheckoutRule.join("a", "b"), "ab") }'))
                narrowed = campaign("fixture-schema-narrowing", narrowed_fixture / "MutationFixture.xcodeproj", "MutationFixture", "MutationFixtureTests", 2, source, operators="arithmetic")
                assert narrowed["summary"]["unbuildable"] == 1 and narrowed["summary"]["killed"] == 1
                assert list((args.output / "fixture-schema-narrowing/logs").glob("schema-narrowed-*.log"))
                if not args.extra_fixtures_only:
                    # Keep the test processes alive after launch so cancellation exercises two active workers.
                    tests = fixture / "Tests/CheckoutRuleSwiftTestingTests.swift"
                    tests.write_text("import Foundation\n" + tests.read_text().replace("func expressEligibility() {", 'func expressEligibility() { if ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] != nil { Thread.sleep(forTimeInterval: 20) }').replace("func parameterizedWeight(weightGrams: Int) {", 'func parameterizedWeight(weightGrams: Int) { if ProcessInfo.processInfo.environment["SWIFT_MUTATION_ID"] != nil { Thread.sleep(forTimeInterval: 20) }'))
                    rule = fixture / source
                    rule.write_text(rule.read_text().replace("cents >= 0 && couponPercent >= 0 && couponPercent <= 100", "(0...100).contains(couponPercent)"))
                    output = args.output / "fixture-cancellation"
                    output.mkdir()
                    with (output / "cli.log").open("w") as log:
                        process = subprocess.Popen(command(project, "MutationFixture", "MutationFixtureTests", 2, output, source, operators="logical"), stdout=log, stderr=subprocess.STDOUT)
                        try:
                            deadline = time.monotonic() + 300
                            while len(list((output / "logs").glob("mutant-*.log"))) < 2:
                                assert process.poll() is None, "Cancellation fixture exited before both workers started"
                                assert time.monotonic() < deadline, "Cancellation fixture startup timed out"
                                time.sleep(0.2)
                            process.terminate()
                            process.wait(timeout=180)
                        finally:
                            if process.poll() is None:
                                process.terminate()
                                process.wait(timeout=180)
                            clean_check()
                    assert process.returncode != 0 and not (output / "report.json").exists()
                    results["checks"].append({"name": "cancel-two-active-workers", "passed": True})

        app_project = args.app_root / "MutationTest.xcodeproj"
        reference = None
        for repetition in range(1, args.repetitions + 1):
            for workers in (1, 2):
                report = campaign(f"app-{workers}-workers-{repetition}", app_project, "MutationTest", "MutationTestAppTests", workers,
                                  "Modules/CheckoutInventory/Sources/CheckoutInventory/InventoryPolicy.swift")
                if reference is None:
                    reference = report
                assert verdicts(reference) == verdicts(report), "App serial/parallel verdict mismatch"
                assert reference["scope"] == report["scope"] and reference["summary"] == report["summary"]
                results["benchmarks"].append({"workers": workers, "repetition": repetition, "seconds": report["execution"]["totalDurationSeconds"], "mutantSeconds": report["timings"]["mutantRunSeconds"], "mutants": report["summary"]["generated"], "testsPerWorker": report["execution"]["baselineTestCount"]})
        if results["benchmarks"]:
            medians = {workers: statistics.median(r["seconds"] for r in results["benchmarks"] if r["workers"] == workers) for workers in (1, 2)}
            results["medianSeconds"] = medians
            results["speedup"] = medians[1] / medians[2]
            assert medians[2] < medians[1], f"Two workers did not improve median total time: {medians}"
    except BaseException as error:
        results["error"] = str(error)
        raise
    finally:
        (args.output / "validation.json").write_text(json.dumps(results, indent=2))
        lines = ["# Xcode worker validation", "", f"Checks completed: {len(results['checks'])}."]
        for check in results["checks"]:
            lines.append(f"- {check['name']}: passed" + (f"; {check['mutants']} mutants, {check['testsPerWorker']} baseline tests per worker, {check['seconds']:.1f}s" if "mutants" in check else ""))
        if "medianSeconds" in results:
            lines += ["", f"Median: 1 worker {results['medianSeconds'][1]:.1f}s; 2 workers {results['medianSeconds'][2]:.1f}s.", f"Speedup: {results['speedup']:.2f}×. Verdicts and test scope matched."]
        if results["error"]:
            lines += ["", f"Failed: {results['error']}"]
        summary = "\n".join(lines) + "\n"
        (args.output / "validation.md").write_text(summary)
        if path := os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(path, "a") as stream:
                stream.write(summary)


if __name__ == "__main__":
    main()
