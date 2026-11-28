#!/usr/bin/env bash
set -euo pipefail

cli=$1
fixture=$2
artifacts=$3
mkdir -p "$artifacts"

project="$fixture/MutationTestIOSApp.xcodeproj"
source_path=Modules/CheckoutDomain/Sources/CheckoutDomain/CheckoutCalculator.swift
test_path=AppTests/Features/Checkout/CheckoutScenarioTests.swift

# Run the real engine on a small deterministic addition to the sample app.
# append(true) generates overlapping statement and expression mutants, while
# the never-called function exercises the no-activation result.
cat >> "$fixture/$source_path" <<'SWIFT'

public func mutestCoveredValue() -> Bool {
    var values = [Bool]()
    values.append(true)
    return values.first ?? false
}

public func mutestUncoveredValue() -> Bool { return true }
SWIFT

cat >> "$fixture/$test_path" <<'SWIFT'

import CheckoutDomain
import XCTest

final class BuildReuseXCTests: XCTestCase {
    func testMutestBuildReuseXCTest() {
        XCTAssertTrue(mutestCoveredValue())
    }
}

struct BuildReuseSwiftTests {
    @Test func mutestBuildReuseSwiftTest() {
        #expect(mutestCoveredValue())
    }
}
SWIFT

device="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in reversed(sorted(devices)):
    if ".iOS-" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit()
sys.exit("No available iPhone simulator")
')"

for pass in cold warm; do
    "$cli" run --project "$project" --project-kind xcode-project \
        --scheme MutationTestIOSApp --xcode-test-plan MutationTestIOSApp \
        --destination-simulator "platform=iOS Simulator,id=$device" \
        --source "$source_path" --test-name testMutestBuildReuseXCTest \
        --test-name mutestBuildReuseSwiftTest --operators boolean,removeSideEffects \
        --narrow-xcode-test-build --xcode-build-timing-summary \
        --xcode-build-cache-dir "$artifacts/../compiled-cache" \
        --xcodebuild-arg CODE_SIGNING_ALLOWED=NO --workers 1 --no-cache \
        --build-timeout 600 --baseline-timeout 180 --mutant-timeout 120 \
        --maximum-integrity-warnings 0 --output "$artifacts/$pass" \
        | tee "$artifacts/$pass.log"
done

python3 - "$artifacts" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
verdicts = []
for name in ("cold", "warm"):
    report = json.loads((root / name / "report.json").read_text())
    scope = report["scope"]
    assert len(scope["tests"]) == 2, scope
    mutants = report["mutants"]
    assert any(m.get("activated") and m["status"] == "killed" for m in mutants), mutants
    assert any(m["status"] == "noCoverage" for m in mutants), mutants
    attempts = report["timings"]["xcodeAttempts"]
    assert any(a["phase"] == "isolatedBuild" and a["exitCode"] == 0 for a in attempts), attempts
    original_logs = [a["log"] for a in attempts if a["phase"] == "originalTest"]
    baseline_output = "\n".join((root / name / "logs" / log).read_text() for log in original_logs)
    assert "testMutestBuildReuseXCTest" in baseline_output, baseline_output
    assert "mutestBuildReuseSwiftTest" in baseline_output, baseline_output
    verdicts.append({m["id"]: m["status"] for m in mutants})
assert verdicts[0] == verdicts[1], verdicts
assert "Compiled Xcode build cache available:" in (root / "warm.log").read_text()
PY
