#!/usr/bin/env bash
set -euo pipefail

# Create a small independent repository with both changed and matching tests.
fixture="${1:?pass a destination directory}"
mkdir -p "$fixture/Sources/Sample" "$fixture/Tests/SampleTests"
cd "$fixture"
git init --quiet
git config user.name 'Mutation CI'
git config user.email 'mutation-ci@example.invalid'
cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Sample", targets: [
    .target(name: "Sample"),
    .testTarget(name: "SampleTests", dependencies: ["Sample"])
])
SWIFT
cat > Sources/Sample/Arithmetic.swift <<'SWIFT'
public enum Arithmetic {
    public static func increment(_ value: Int) -> Int { value + 0 }
}
SWIFT
cat > Sources/Sample/Unchanged.swift <<'SWIFT'
public enum Unchanged {
    public static func enabled() -> Bool { true }
}
SWIFT
cat > Tests/SampleTests/ArithmeticTests.swift <<'SWIFT'
import Sample
import Testing
@Suite struct ArithmeticTests {
    @Test func increments() { #expect(Arithmetic.increment(4) == 5) }
}
SWIFT
cat > Tests/SampleTests/ChangedTests.swift <<'SWIFT'
import Sample
import Testing
@Suite struct ChangedTests {
    @Test func checksAnotherInput() { #expect(Arithmetic.increment(2) == 3) }
}
SWIFT
git add .
git commit --quiet -m base
cat > Sources/Sample/Arithmetic.swift <<'SWIFT'
public enum Arithmetic {
    public static func increment(_ value: Int) -> Int { value + 1 }
}
SWIFT
printf '\n// Updated in this pull request.\n' >> Tests/SampleTests/ChangedTests.swift
git add .
git commit --quiet -m change
