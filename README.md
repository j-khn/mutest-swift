# Swift Mutation Testing

A native Swift mutation-testing engine and CLI implementing the language-neutral `mutation-testing-spec` 1.x contract. This package owns SwiftSyntax rewrites and SwiftPM/Xcode execution.

## Status

V1 development target: SwiftPM packages and Xcode projects/workspaces; Swift Testing and XCTest; seven operator families; changed-source and explicit test selection; mutation schemas with activation markers and isolated fallback; independent timeouts; resumable journal/cache; JSON and Markdown reports; quality gates; GitHub Action.

The operator campaign tiers are currently **experimental** until the documented campaign is run against at least three real Swift packages. No operator has been promoted based on synthetic fixture results. See [Swift operator syntax and campaign policy](Docs/OPERATORS.md). `stryker.json` follows the [Stryker mutation testing report schema](https://github.com/stryker-mutator/mutation-testing-elements/blob/master/packages/report-schema/src/mutation-testing-report-schema.json).

## CLI

```sh
swift run swift-mutation-testing run --project . --operator-tier experimental
swift run swift-mutation-testing run --project . \
  --source Sources/CheckoutDomain/ShippingCalculator.swift \
  --test-file Tests/CheckoutDomainTests/ShippingCalculatorTests.swift
```

Use `--suite` and `--test` for native test identifiers. Omitting all test selectors runs all tests in the configured test target. Explicit selectors that cannot be resolved fail instead of expanding to all tests. Xcode test identifiers preserve parameter labels for parameterized declarations and are checked for nonzero execution so `xcodebuild` cannot silently accept a selector that matched no tests. `--source` limits mutation locations; test selection remains independent so callers can run the full suite to detect ripple effects.

`--project-kind swift-package|xcode-project|xcode-workspace`, `--scheme`, `--test-target`, and `--destination` configure the native adapter. Baseline and mutant builds run in a disposable copy of the project, keeping build products and project-local test side effects out of the source checkout. For Xcode tests, runtime activation markers are captured from the test process output, avoiding assumptions about simulator clone or app-container paths. Timeouts are independently configurable with `--build-timeout`, `--baseline-timeout`, and `--mutant-timeout` (seconds). `--parallelism` controls isolated workers. `--output` selects the report directory. The append-only journal defaults to that directory; `--cache-path` selects a separate cache directory, `--no-resume` skips cached verdicts, and `--no-cache` disables journal reads and writes.

JSON run configuration supports the same settings, including output formats and suppression behavior. For example:

```json
{
  "specVersion": "1.0.0",
  "project": { "kind": "swiftPackage", "path": "." },
  "operatorTier": "experimental",
  "parallelism": 2,
  "cache": { "enabled": true, "path": ".swift-mutation-cache" },
  "suppression": { "enabled": true, "requireReason": true },
  "output": { "directory": ".swift-mutation-testing", "formats": ["console", "json", "markdown"] }
}
```

When `requireReason` is enabled, a suppression directive without a reason does not suppress its mutant. JSON output writes both the canonical `report.json` and `stryker.json`; Markdown output writes `report.md`.

For `maximumScoreDrop`, the baseline must have the same source list and test selection as the current run; a scope mismatch fails the gate instead of comparing unrelated scores. `failOnNewSurvivors` compares stable mutant IDs, so it can compare a changed source selection with a broader baseline report.

## Engine layout

- `MutationTestingSpec`: Codable contract types and scoring/gate rules.
- `SwiftMutationTesting`: source discovery, SwiftSyntax operators, native test adapters, process runner, journal/cache, orchestration, and report writers.
- `swift-mutation-testing`: CLI.

## Validation

```sh
swift test
swift run swift-mutation-testing validate --project Fixtures/SwiftPackage
```

## License

MIT. See `LICENSE`.
