# mutest-swift

`mutest-swift` is a native Swift mutation-testing engine, command-line tool, and GitHub Action. It implements the language-neutral [`mutest-core`](https://github.com/jamilkhan55/mutest-core) contract and runs tests for SwiftPM packages and Xcode projects/workspaces using XCTest or Swift Testing.

## Requirements

- macOS 14 or newer.
- Xcode with a Swift 6.4-compatible toolchain. The package pins SwiftSyntax 604.0.0; development and CI use Xcode's `swift` and `xcodebuild` tools.
- Git and network access for the first SwiftPM dependency resolution.

## 1. Clone and build the tool

```sh
git clone https://github.com/jamilkhan55/mutest-swift.git
cd mutest-swift
swift --version
swift test
swift run swift-mutation-testing version
```

`swift test` builds the engine and runs its unit and integration tests. The CLI is run with `swift run swift-mutation-testing` from this checkout.

## 2. Try a mutation run with the included sample

First check that the sample Swift package can be discovered:

```sh
swift run swift-mutation-testing validate \
  --project Fixtures/SwiftPackage \
  --project-kind swift-package
```

Then mutate the sample's relational and logical operators:

```sh
swift run swift-mutation-testing run \
  --project Fixtures/SwiftPackage \
  --project-kind swift-package \
  --operators relational,logical \
  --operator-tier experimental \
  --parallelism 2 \
  --output /tmp/mutest-report
```

This runs the fixture's XCTest and Swift Testing tests. The command prints the score and writes `report.json`, `stryker.json`, and `report.md` under `/tmp/mutest-report`.

The sample Xcode app and test target are in `Fixtures/XcodeApp`. To run them in a simulator, use your installed simulator name:

```sh
swift run swift-mutation-testing run \
  --project Fixtures/XcodeApp/MutationFixture.xcodeproj \
  --project-kind xcode-project \
  --scheme MutationFixture \
  --test-target MutationFixtureTests \
  --destination 'platform=iOS Simulator,name=iPhone 17' \
  --operator-tier experimental
```

Change `iPhone 17` to a simulator installed on your Mac. For a workspace, use `--project-kind xcode-workspace` and pass the `.xcworkspace` path.

## 3. Run it on your own project from the CLI

From this repository, point `--project` at your Swift package or Xcode project. For example:

```sh
swift run swift-mutation-testing validate \
  --project /path/to/MyPackage \
  --project-kind swift-package

swift run swift-mutation-testing run \
  --project /path/to/MyPackage \
  --project-kind swift-package \
  --source Sources/CheckoutDomain \
  --test-file Tests/CheckoutDomainTests/CheckoutCalculatorTests.swift \
  --operator-tier experimental \
  --output /tmp/my-mutation-report
```

`--source` selects where mutants are made. `--test-file`, `--suite`, and `--test` select tests to run. If you omit test selectors, the full configured test target runs, even when `--source` narrows the mutation locations; this is useful for detecting ripple effects.

For an Xcode project, replace the project options with the project path and its test settings:

```sh
swift run swift-mutation-testing run \
  --project /path/to/MyApp.xcodeproj \
  --project-kind xcode-project \
  --scheme MyApp \
  --test-target MyAppTests \
  --destination 'platform=iOS Simulator,name=iPhone 17' \
  --operator-tier experimental
```

All seven operators are currently experimental. `conservative` and `default` tiers stay unavailable until real-package campaign evidence supports promotion.

## 4. Run it in GitHub Actions

The composite action in this repository wraps the same CLI, adds the Markdown report to the job summary, and uploads the reports as the `swift-mutation-testing-report` artifact.

`mutest-swift` is private. To use it from another private repository owned by `jamilkhan55`, first open **mutest-swift → Settings → Actions → General → Access** and allow access from repositories owned by `jamilkhan55`. GitHub requires this setting before another repository can use an action from a private repository. [GitHub: sharing actions from a private repository](https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories)

In the consuming repository, create `.github/workflows/mutation.yml`:

```yaml
name: Mutation testing

on:
  workflow_dispatch:
  schedule:
    - cron: "0 2 * * 1-5"

jobs:
  mutation-testing:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode toolchain
        shell: bash
        run: |
          set -euo pipefail
          if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
            echo "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >> "$GITHUB_ENV"
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
          fi
          xcode-select -p
          xcodebuild -version
          swift --version

      - name: Run mutation testing
        uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@326ff611154cd0fd3ae5a71c9432ef1d25dee3cb
        with:
          project-path: .
          project-kind: swift-package
          operator-tier: experimental
          parallelism: "2"
          maximum-integrity-warnings: "0"
```

This example runs the full source and test target when manually dispatched or on the weekday schedule. To target changed code, pass one relative source path per line using `source:`; leave test selectors empty to keep running the full suite.

For an Xcode app, change the action inputs to match its project:

```yaml
with:
  project-path: MyApp.xcodeproj
  project-kind: xcode-project
  scheme: MyApp
  test-target: MyAppTests
  destination: platform=iOS Simulator,name=iPhone 17
```

Use a simulator name installed on the self-hosted Mac. The action can also accept `test-file`, `suite`, or `test` selectors. The full SHA in `uses:` pins the action to a specific commit; update it when you choose a newer mutest-swift version. GitHub supports this `{owner}/{repo}/{path}@{ref}` syntax for actions in another repository. [GitHub: finding and customizing actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/find-and-customize-actions)

## Reports and gates

JSON output includes the canonical `report.json` and Stryker-compatible `stryker.json`; Markdown output is `report.md`. The action publishes the Markdown in the job summary and uploads the report directory. CLI and action options can enforce minimum score, maximum score drop from a baseline report, new-survivor checks, and integrity-warning limits.

## Project layout

- `Sources/MutationTestingSpec`: Swift types for the shared `mutest-core` contract.
- `Sources/SwiftMutationTesting`: source discovery, SwiftSyntax operators, test adapters, process runner, cache, orchestration, and reports.
- `Sources/swift-mutation-testing`: CLI entry point.
- `Fixtures/SwiftPackage` and `Fixtures/XcodeApp`: runnable sample projects.
- `.github/actions/run-mutation-testing`: reusable composite action.
- `.github/workflows/mutation.yml`: this repository's manual and nightly mutation campaign.

## License

MIT. See [`LICENSE`](LICENSE).
