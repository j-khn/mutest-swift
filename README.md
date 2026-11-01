# mutest-swift

## What is Mutation Testing?

Mutation testing checks whether your unit tests catch mistakes.

Instead of only checking whether your code passes tests, a tool temporarily changes your code in small ways—like changing `+` to `-` or `true` to `false`—and runs your existing tests.

- If a test fails, it caught the change.
- If the tests pass, they missed the change. Your test suite may have a blind spot.

Mutation testing is not a way to write code. You do not write special code for it; a tool temporarily changes your existing code to check your tests.

<details>
<summary>Mutation testing words</summary>

| Word | Simple meaning |
| --- | --- |
| **Baseline test** | Tests run on the original code first. If these fail, the tool stops without a score. |
| **Mutant** | One small, intentional code change. |
| **Generated mutants** | All candidate changes the tool created. Some may not compile or reach a test run. |
| **Killed** | A test failed after the changed code ran. The tests caught that change. |
| **Detected** | Changes caught by a failing test, plus timed-out changes confirmed to have run. |
| **Survived** | The selected tests passed while the change was active. This may point to a missing test. |
| **No coverage** | The selected tests passed, but did not run the changed code. |
| **Unbuildable** | The changed code did not compile. It is excluded from the mutation score. |
| **Mutation score** | Detected mutants divided by detected plus undetected mutants. |

</details>

## What is mutest-swift?

`mutest-swift` is a mutation-testing tool for Swift packages and Xcode projects or workspaces. It temporarily changes your source code and runs your tests; your original files stay unchanged.

## Quick Start

### 1. Run locally

Requirements: macOS 14 or newer, Swift 6.0 or newer, and Python 3. Install Xcode to test Xcode projects or iOS apps.

```sh
mkdir -p ~/Tools
cd ~/Tools
git clone https://github.com/jamilkhan55/mutest-swift.git
cd mutest-swift
./run /path/to/MyApp.xcodeproj
```

For a Swift package, pass its folder instead:

```sh
./run /path/to/MySwiftPackage
```

For an Xcode project or workspace, the tool asks which scheme, test target, and simulator to use. Press Enter to choose the first scheme or simulator. You can pass those choices as options to skip the prompts.

<details>
<summary>CLI options</summary>

| Option | Values or default | What it does |
| --- | --- | --- |
| `PROJECT` | Swift package folder, `.xcodeproj`, `.xcworkspace`, or folder containing one; defaults to `.` | Project to test. |
| `--scheme NAME` | Xcode scheme | Selects an Xcode scheme. Asked interactively if missing. |
| `--target NAME` or `--test-target NAME` | Xcode test target | Selects the tests to run. Asked interactively if missing. |
| `--destination VALUE` | Xcode destination string | Chooses the simulator. Asked interactively if missing. |
| `--parallelism N` or `--parallelization N` | Positive number; default `2` | Runs up to this many mutants at once. |
| `--source PATH` | Source file or folder; repeatable | Limits where mutations are made. No value means all discovered source files. |
| `--target-file PATH` or `--test-file PATH` | Test file; repeatable | Selects tests from the named file. No test selectors means all tests in the target. |
| `--suite NAME` | Test suite name; repeatable | Selects tests in the named suite. |
| `--target-tests NAME` or `--test NAME` | Test name; repeatable | Selects the named test. |
| `--operators NAMES` | Comma-separated: `relational`, `boolean`, `logical`, `arithmetic`, `negateConditional`, `swapTernary`, `removeSideEffects` | Limits the kinds of changes made. |
| `--operator-tier TIER` | `experimental` (default) or `all` | Chooses the operator set. `conservative` and `default` are not available yet. |
| `--xcodebuild-arg NAME=VALUE` | Xcode build setting; repeatable | Passes a setting to Xcode builds. |
| `--output PATH` | Folder | Writes reports to this folder. Default: `.swift-mutation-testing` in the project. |
| `--no-cache` | Flag | Does not reuse cached mutant results. |
| `--no-resume` | Flag | Starts without reusing results from an interrupted run. |
| `--validate` | Flag | Checks project settings without running mutation tests. |
| `--help` | Flag | Shows the full command help. |

Examples:

```sh
./run --help
./run /path/to/MyApp.xcodeproj --scheme MyApp --target MyAppTests --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' --parallelism 2
./run /path/to/MyApp.xcodeproj --source Sources/Checkout --target-file CheckoutTests.swift
```

</details>

### 2. Run with GitHub Actions

GitHub reads workflow files from `.github/workflows/`, so create your workflow there. The example below runs on pushes and pull requests to `main`; change the branch name if your repository uses another one. It runs the full configured test target unless you add test selectors.

<small><em>Note: `mutest-swift` is private for now. You need permission to clone it and to let your repository use its GitHub Action. Grant Action access in `mutest-swift` → Settings → Actions → General → Access. <a href="https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories">GitHub explains this setting</a>.</em></small>

Create `.github/workflows/mutation.yml`:

```yaml
name: Mutation tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

jobs:
  mutation-testing:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check Xcode
        run: xcodebuild -version
      - name: Run mutation tests
        uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
        with:
          project-path: MyApp.xcodeproj
          project-kind: xcode-project
          scheme: MyApp
          test-target: MyAppTests
          destination: platform=iOS Simulator,name=iPhone 17,OS=latest
```

Replace `MyApp` and the simulator name with values from your project and runner. For a Swift package, use `project-path: .` and `project-kind: swift-package`; omit `scheme`, `test-target`, and `destination`. The Action builds the tool, runs the tests, adds the Markdown report to the workflow summary, and uploads the reports.

<details>
<summary>GitHub Action inputs</summary>

| Input | Values or default | What it does |
| --- | --- | --- |
| `project-path` | Required | Package folder, `.xcodeproj`, or `.xcworkspace`. |
| `project-kind` | `swift-package` (default), `xcode-project`, `xcode-workspace` | Project type. |
| `scheme`, `test-target`, `destination` | Xcode values | Xcode scheme, test target, and simulator destination. |
| `source` | One relative path per line; blank means all discovered source | Limits mutation locations. |
| `test-file`, `suite`, `test` | One selector per line; blank means full target | Optionally limits tests. |
| `operator-tier` | `experimental` (default) or `all` | Chooses the operator set. `conservative` and `default` are not available yet. |
| `parallelism` | Positive number; default `2` | Maximum number of concurrent mutants. |
| `xcodebuild-arg` | One `NAME=VALUE` per line | Extra Xcode build settings. |
| `cache-path` | Folder; blank uses default locations | Sets where reusable results and the CLI build cache are stored. |
| `no-cache`, `no-resume` | `true` or `false`; default `false` | Disables cache use or resuming prior results. |
| `no-suppressions`, `require-suppression-reason` | `true` or `false`; default `false` | Controls mutation suppression comments. |
| `build-timeout` | Seconds; default `600` | Maximum build time. |
| `baseline-timeout` | Seconds; default `300` | Maximum baseline test time. |
| `mutant-timeout` | Seconds; default `120` | Maximum test time per mutant. |
| `minimum-score` | Number from `0` to `1` | Fails the job if the score is too low. |
| `baseline-report` | Path to an earlier `report.json` | Compares this run with an earlier report. |
| `maximum-score-drop` | Number from `0` to `1` | Maximum allowed score drop from the baseline report. |
| `fail-on-new-survivors` | `true` or `false`; default `false` | Fails if this run adds survivors compared with the baseline. |
| `maximum-integrity-warnings` | Zero or higher; default `0` | Maximum allowed integrity warnings. |
| `output-path` | Folder; default `.swift-mutation-testing` | Where reports are written. |
| `tool-path` | Executable path; blank by default | Use a previously built CLI. Usually leave blank. |

</details>

## What does a mutation run do?

The tool first runs the selected tests on the original code. If they fail, it stops. It then tries small code changes, one mutant at a time. If a test fails while a mutant is confirmed active, that mutant is killed. If tests pass, the tool finishes the selected test run to check whether the mutant survived or had no coverage.

By default, it mutates all discovered source files and runs all tests in the configured test target. `--source` limits which files are changed; it does not limit tests. Use `--test-file`, `--suite`, or `--test` to select fewer tests.

Swift package dependencies are resolved from `Package.swift`. Local sibling packages are copied into the isolated sandbox with their relative paths preserved. Git dependencies use SwiftPM or Xcode resolution, including the manifest's version, exact version, tag, branch, or revision requirement. Source files and resources declared by package targets are copied with their package.

Mutation types include changing comparisons, Boolean values, logical and arithmetic operators, conditions, ternary branches, and standalone calls. See [Operators](Docs/OPERATORS.md) for supported Swift syntax and limits.

## What affects run time and cache reuse?

- Xcode simulator runs can use up to `--parallelism` workers (default: `2`). Swift package runs use parallel workers with Swift Testing; packages that use XCTest run serially.
- A verified test failure can end that mutant's run early. Survivors and mutants with no coverage finish the selected test scope.
- JSON and Markdown reports include test counts and phase timings, such as build, baseline, mutant runs, and cleanup.
- The verdict cache can reuse completed mutants on later runs when the code, tests, selectors, build settings, toolchain, and tool version still match.
- `--no-cache` disables cache reads and writes. `--no-resume` ignores earlier results but still saves new ones.

## License

No license is provided at this time.
