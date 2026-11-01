#!/usr/bin/env python3
"""Real simulator acceptance checks and sequential 1/2-worker benchmarks. Run on CI."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time





def simulators():
    data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))
    return {d["udid"]: d for devices in data["devices"].values() for d in devices}


def verdicts(report):
    return {m["id"]: (m["status"], m["activated"]) for m in report["mutants"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", type=Path, required=True)
    parser.add_argument("--app-root", type=Path, required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=3)
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
               "--parallelism", str(workers), "--operator-tier", "experimental",
               "--no-cache", "--no-resume", "--output", str(output),
               "--xcodebuild-arg", "ARCHS=arm64", "--xcodebuild-arg", "ONLY_ACTIVE_ARCH=YES",
               "--xcodebuild-arg", "CODE_SIGNING_ALLOWED=NO"]
        for path in source if isinstance(source, (list, tuple)) else (source,):
            cmd += ["--source", path]
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
        results["checks"].append({"name": name, "mutants": report["summary"]["generated"], "sourceFiles": len(report["scope"]["sources"]), "testsPerWorker": report["execution"]["baselineTestCount"], "seconds": report["execution"]["totalDurationSeconds"]})
        return report

    try:
        app_project = args.app_root / "MutationTest.xcodeproj"
        app_sources = [
            "Modules/CheckoutCustomer/Sources/CheckoutCustomer/LoyaltyPointsCalculator.swift",
            "Modules/CheckoutDomain/Sources/CheckoutDomain/CheckoutCalculator.swift",
            "Modules/CheckoutInventory/Sources/CheckoutInventory/InventoryPolicy.swift",
            "Modules/CheckoutShipping/Sources/CheckoutShipping/ShippingCalculator.swift",
        ]
        reference = None
        for repetition in range(1, args.repetitions + 1):
            for workers in (1, 2):
                report = campaign(f"app-{workers}-workers-{repetition}", app_project, "MutationTest", "MutationTestAppTests", workers,
                                  app_sources)
                if reference is None:
                    reference = report
                assert verdicts(reference) == verdicts(report), "App serial/parallel verdict mismatch"
                assert reference["scope"] == report["scope"] and reference["summary"] == report["summary"]
                results["benchmarks"].append({"workers": workers, "repetition": repetition, "seconds": report["execution"]["totalDurationSeconds"], "mutantSeconds": report["timings"]["mutantRunSeconds"], "mutants": report["summary"]["generated"], "sourceFiles": len(report["scope"]["sources"]), "testsPerWorker": report["execution"]["baselineTestCount"]})
        if results["benchmarks"]:
            medians = {workers: statistics.median(r["seconds"] for r in results["benchmarks"] if r["workers"] == workers) for workers in (1, 2)}
            results["medianSeconds"] = medians
            results["speedup"] = medians[1] / medians[2]
            assert medians[2] < medians[1], f"Two workers did not improve median total time: {medians}"
    except BaseException as error:
        results["error"] = str(error) or type(error).__name__
        raise
    finally:
        (args.output / "validation.json").write_text(json.dumps(results, indent=2))
        lines = ["# Xcode worker validation", "", f"Checks completed: {len(results['checks'])}."]
        for check in results["checks"]:
            lines.append(f"- {check['name']}: passed" + (f"; {check['mutants']} mutants across {check['sourceFiles']} source files, {check['testsPerWorker']} baseline tests per worker, {check['seconds']:.1f}s" if "mutants" in check else ""))
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
