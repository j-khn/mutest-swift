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

Requirements: macOS 14 or newer, Swift 6.0 or newer, and Python 3. Install Xcode to test Xcode projects or iOS apps. Swift packages can also run through the CLI or GitHub Action on Linux when their code, dependencies, and tests support Linux. The interactive `./run` launcher is for Xcode and iOS simulator projects.

```sh
mkdir -p ~/Tools
cd ~/Tools
git clone https://github.com/j-khn/mutest-swift.git
cd mutest-swift
./run /path/to/MyApp.xcodeproj
```

For an iOS or iPadOS Swift package inside an Xcode project or workspace, pass the package folder or its containing Xcode project:

```sh
./run /path/to/MyApp/Modules/MyPackage
# or
./run /path/to/MyApp/MyApp.xcodeproj
```

When you pass a package folder, `./run` finds its enclosing Xcode project or workspace and runs the matching package scheme on a simulator. It does not fall back to `swift test` on the Mac. A package without an enclosing Xcode project or workspace cannot run iOS or iPadOS tests this way.

For an Xcode project or workspace, the tool asks which scheme, test scope, and simulator to use. Choose multiple test targets to run all tests in each. You can also add file, suite, or test-name filters from other test targets in the same scheme; those filters add only their matches. If you pass a package folder and its name matches an Xcode scheme, that scheme is selected automatically. Press Enter to choose the first option in other menus. You can pass the choices as options to skip the prompts. iPhone and iPad simulators are supported.

<details>
<summary>CLI options</summary>

| Option | Values or default | What it does |
| --- | --- | --- |
| `PROJECT` | iOS/iPadOS package folder with an enclosing Xcode project/workspace, `.xcodeproj`, `.xcworkspace`, or folder containing one; defaults to `.` | Project to test. |
| `--scheme NAME` | Xcode scheme | Selects an Xcode scheme. Asked interactively if missing. |
| `--test-target NAME` | Xcode test target; repeatable | Runs every test in each named target. |
| `--test-package-root PATH` | Local Swift package folder; repeatable | Maps test files from a package that is part of the selected Xcode scheme. The launcher detects this automatically when you select a package scheme. |
| `--source-commit COMMIT` | Commit or ref currently checked out | Turns on commit-based selection. Defaults to changed production files and changed plus matching tests. |
| `--source-base COMMIT` | Commit or ref; defaults to the source commit's parent | Compares a commit range, such as all commits since the last nightly. |
| `--source-scope` | `changed` (commit mode default) or `all` | Mutates only production Swift files changed in the commit range, or all source files. |
| `--test-scope` | `changed`, `matching`, `changed-and-matching` (commit mode default), `affected-packages`, or `all` | Chooses changed or matching test files, affected package test targets, or the full test plan. |
| `--test-file-suffix SUFFIX` | `Tests.swift` by default; repeatable | Looks for files such as `FooTests.swift` when changed source is `Foo.swift`. |
| `--destination-simulator VALUE` | Xcode simulator destination string | Chooses the simulator. Asked interactively if missing. |
| `--workers COUNT` | Positive number; default `2` | Runs up to this many mutants at once. |
| `--mutant-timeout SECONDS` | Positive number; default `30` | Maximum time for one mutant's test command. Increase it for slow integration tests, such as WebSocket or WebRTC tests. |
| `--mutation-source PATH` | Swift production source file or folder; repeatable | Limits where mutations are made. No value means all discovered source files. |
| `--test-file PATH` | Test file path; repeatable | Adds every test in that file, including from another target in the chosen scheme. |
| `--test-suite NAME` | Suite name; repeatable | Adds tests in that suite, including from another target in the chosen scheme. |
| `--test-name NAME` | Test function or custom name; repeatable | Adds matching test(s), including from another target in the chosen scheme. |
| `--operators NAMES` | Comma-separated: `relational`, `boolean`, `logical`, `arithmetic`, `negateConditional`, `swapTernary`, `removeSideEffects` | Limits the kinds of changes made. |
| `--operator-tier TIER` | `experimental` (default) or `all` | Chooses the operator set. `conservative` and `default` are not available yet. |
| `--xcodebuild-arg NAME=VALUE` | Xcode build setting; repeatable | Passes a setting to Xcode builds. |
| `--xcode-build-jobs auto\|N` | Defaults to `auto` | Lets Xcode choose build concurrency independently of test workers. Set a number to cap it. |
| `--xcode-build-cache-dir PATH` | Optional directory outside the checkout | Reuses compiled Xcode products between runs on the same runner. |
| `--xcode-test-plan NAME` | Optional plan in the selected scheme | Uses the named Xcode test plan. |
| `--full-xcode-test-build` | Optional | Builds the full scheme even when selecting specific tests. |
| `--xcode-code-coverage on\|off` | Uses the scheme setting by default | Overrides Xcode coverage instrumentation. Mutest still tracks mutant activation. |
| `--xcode-build-timing-summary` | Optional | Includes Xcode's task timing summary in build logs. |
| `--cloned-source-packages-dir PATH` | Existing Xcode `SourcePackages` directory | Reuses package checkouts from that directory. |
| `--package-cache-path PATH` | Existing Xcode package cache directory | Reuses downloaded package and binary artifacts. |
| `--skip-package-resolution` | Flag; Xcode projects only | Skips dependency resolution and disables automatic fetching during Xcode project builds. Requires `--cloned-source-packages-dir`. |
| `--output PATH` | Folder | Writes reports to this folder. Default: `.swift-mutation-testing` in the project. |
| `--no-cache` | Flag | Does not reuse cached mutant results. |
| `--no-resume` | Flag | Starts without reusing results from an interrupted run. |
| `--validate` | Flag | Checks project settings without running mutation tests. |
| `--help` | Flag | Shows the full command help. |

An Xcode scheme is the build and test plan. A test target is one test bundle inside that scheme. Every target and test selected below must be included in the scheme's test plan.

Each `--test-target` adds **all tests in that target**. Each file, suite, or name option adds only its matches, even when they belong to other targets in the same scheme. All filters are combined with **OR**; duplicates run once. A file selects every test in that file; use `--test-name` to select individual tests. If a selector name matches multiple targets, qualify it as `TargetName::selector`.

When test files belong to a local Swift package inside an Xcode project, `./run` passes the selected package to test discovery automatically. For a direct CLI command, add `--test-package-root /path/to/the/package` so the tool can map its test files to their Swift package test target.

Commit mode compares the checked-out commit with `--source-base` (or its first parent). A changed `Foo.swift` matches a tracked `FooTests.swift` anywhere in the project. Changed test files are also included by default. Use `--test-scope all` to keep the full test plan for ripple checks. Do not pass `--test-target` when you want only selected files; a target always adds every test in that target.

Use `--test-scope affected-packages` with `--source-scope changed` to run all test targets declared by each changed source file's nearest Swift package. For Xcode, those targets must be in the scheme's test plan. Files outside a Swift package produce an error; select their Xcode test targets explicitly instead. A change with no production Swift files skips the mutation run.

Examples:

```sh
./run --help
./run /path/to/MyApp.xcodeproj --scheme MyApp --test-target MyAppTests --destination-simulator 'platform=iOS Simulator,name=iPhone 17,OS=latest' --workers 2
./run /path/to/MyApp.xcodeproj --mutation-source Sources/Checkout/A.swift --mutation-source Sources/Checkout/B.swift --test-file CheckoutATests.swift --test-file CheckoutBTests.swift
./run /path/to/MyApp.xcodeproj --scheme MyApp --test-target TargetA --test-target TargetB --test-file CTests.swift --test-suite 'TargetETests::Suite1' --test-name 'TargetDTests::testABC' --destination-simulator 'platform=iOS Simulator,name=iPhone 17,OS=latest'
./run /path/to/MyApp.xcodeproj --scheme MyApp --source-commit HEAD --source-base main --test-file-suffix Tests.swift
```

The last command runs all tests in A and B, every test in `CTests.swift`, all tests in `Suite1` from E, and the one named test from D. Xcode builds the selected test targets and their dependencies when the scheme supports it. Test runs use only this combined selection. Replace the sample target and selector names with names from your scheme.

</details>

### 2. Run in a GitHub Actions workflow

You can build and run mutest-swift directly from its repository. This example uses GitHub's checkout action for your app; it does not call a mutest-swift action. It fetches a fixed mutest-swift commit into the runner's temporary directory, then builds and runs the CLI. Your runner needs Git, Swift, Xcode, and an iOS simulator. SwiftPM also needs access to the tool's dependencies.

Create `.github/workflows/mutation.yml` and replace the project, scheme, simulator, and runner labels with your own:

```yaml
name: PR mutation testing

on:
  pull_request:

permissions:
  contents: read

jobs:
  mutation-testing:
    runs-on: [self-hosted, macos]
    timeout-minutes: 120
    steps:
      - name: Check out the PR
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          fetch-depth: 0
          persist-credentials: false

      - name: Build and run mutest-swift
        id: mutation
        env:
          BASE_SHA: ${{ github.event.pull_request.base.sha }}
          HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        run: |
          set -euo pipefail
          tool_dir="$(mktemp -d "${RUNNER_TEMP}/mutest-swift.XXXXXX")"
          trap 'rm -rf "$tool_dir"' EXIT
          git -C "$tool_dir" init --quiet
          git -C "$tool_dir" remote add origin https://github.com/j-khn/mutest-swift.git
          git -C "$tool_dir" fetch --depth 1 origin refs/tags/v0.3.10
          git -C "$tool_dir" checkout --quiet --detach FETCH_HEAD
          swift build --package-path "$tool_dir" --product swift-mutation-testing
          bin_dir="$(swift build --package-path "$tool_dir" --show-bin-path)"
          base="$(git merge-base "$BASE_SHA" "$HEAD_SHA")"
          report_dir="${RUNNER_TEMP}/mutest-report-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
          mkdir -p "$report_dir"
          rm -f "$report_dir/report.md" "$report_dir/report.json"
          "$bin_dir/swift-mutation-testing" run \
            --project MyApp.xcodeproj --project-kind xcode-project \
            --scheme MyApp --destination-simulator 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
            --source-commit "$HEAD_SHA" --source-base "$base" --source-scope changed \
            --test-scope changed-and-matching --workers 1 --no-cache \
            --baseline-timeout 1800 --mutant-timeout 300 --output "$report_dir"
          if [[ -f "$report_dir/report.md" ]]; then
            cat "$report_dir/report.md" >> "$GITHUB_STEP_SUMMARY"
            if grep -q '^# Mutation testing skipped$' "$report_dir/report.md"; then
              echo "run-status=skipped" >> "$GITHUB_OUTPUT"
            else
              echo "run-status=completed" >> "$GITHUB_OUTPUT"
            fi
          else
            echo 'Mutation report was not produced. Check the earlier logs for the failure.' >> "$GITHUB_STEP_SUMMARY"
            exit 1
          fi

      - name: Upload mutation report
        if: always() && steps.mutation.outputs.run-status != 'skipped'
        uses: actions/upload-artifact@v4
        with:
          name: mutation-report
          path: ${{ runner.temp }}/mutest-report-${{ github.run_id }}-${{ github.run_attempt }}/
          if-no-files-found: ignore
```

`changed-and-matching` selects changed test files and test files whose names match changed source files, such as `Foo.swift` and `FooTests.swift`. Matching uses filenames. To include a known related test file with a different name or in another target, pass `--test-file PATH` alongside the scope. Mutest does not currently derive test-to-source coverage for individual tests. All selected tests must be in the scheme's test plan. If the scope selects no test files, mutest-swift exits successfully, writes a skip report, and does not calculate a mutation score. For the full test plan, use `--test-scope all`.

A Swift file stays in the change scope when its only edit is a comment,
formatting, or a blank line. Selected tests run against the original code first
as the mutation baseline. The same test selection is used when checking mutants.

### Xcode build reuse

Within a run, original, shared, and isolated builds reuse one source tree and
DerivedData directory. Shared-schema tests can run across simulator workers.
Isolated mutants build and test one at a time so source-relative fixtures see
the same source tree for the entire test command.

For repeated runs on a trusted Mac runner, pass `--xcode-build-cache-dir` with
a dedicated local path outside the checkout, output and dependency caches.
Concurrent runs that find the cache busy use a temporary workspace. The next
run discards incomplete build state after an interrupted run. Each campaign
builds and validates the original code again. Omit the flag to use a temporary
workspace. `--no-cache` controls the mutation verdict journal independently.
Keep the checkout location, explicit package directory paths, and Xcode
toolchain stable across runs for cache reuse. The cache uses separate entries
for different build inputs such as a changed scheme or toolchain. To reclaim
disk space, remove the dedicated cache directory while no runs are using it.

When you select specific tests or test targets, mutest-swift narrows the
shared scheme and test plan in its isolated copy. Xcode builds the selected
targets and their required hosts and dependencies. If the scheme cannot be
narrowed safely, mutest-swift logs the reason and uses the original graph.
Pass `--full-xcode-test-build` for schemes that need extra build targets.

The mutation run already builds the original code and runs the selected tests
before applying any mutations. A separate `xcodebuild build-for-testing` step
from your checkout uses a different source path and DerivedData. If that step
exists only to check the mutation baseline, remove it to avoid building twice.

The report separates original compilation, schema compilation, isolated
compilation, and test command times. Parallel commands can overlap. Use total
time for elapsed time. See `logs/xcode-command-timings.json` for individual
attempts, including retries. Use `--xcode-build-timing-summary` for Xcode's
task breakdown in the build logs and Xcode result bundles under `build-results/`.

For a runner with pre-resolved Xcode packages, add `--cloned-source-packages-dir "$HOME/Desktop/swiftpm" --package-cache-path "$HOME/Desktop/swiftpm_cache" --skip-package-resolution` to the `swift-mutation-testing run` command, using the paths on your runner.
The checkout directory and package cache must already have the revisions pinned by the project's `Package.resolved` file and any required binary artifacts. If a checkout or artifact is missing, Xcode reports the build failure. Use per-run copies of shared caches when jobs can run at the same time. These options are for the CLI and `./run`; the reusable GitHub Action does not expose them.

A PR without changed production Swift files, or with no tests selected for the requested test scope, skips mutation testing and records the reason in `report.md`. Run ordinary unit tests in a separate CI job if they should also run for test-only PRs. For Swift packages use `--project . --project-kind swift-package` and omit the Xcode scheme and simulator options. On a persistent runner, use trusted runner configuration and install the required toolchain and simulator.

The repository also provides a reusable GitHub Action for environments that permit it. It builds the same CLI and manages the report summary and artifact. Its inputs are listed below.

<details>
<summary>GitHub Action inputs</summary>

| Input | Values or default | What it does |
| --- | --- | --- |
| `project` | Required | Package folder, `.xcodeproj`, or `.xcworkspace`; matches `--project`. |
| `project-kind` | `swift-package` (default), `xcode-project`, `xcode-workspace` | Project type. |
| `scheme`, `destination-simulator` | Required for Xcode projects | Xcode scheme and simulator destination; match `--scheme` and `--destination-simulator`. |
| `test-target` | One Xcode test target per line; optional | Runs every test in each listed target. Omit it to use the scheme's full test plan when there are no selectors. |
| `test-package-root` | One package path per line; optional | Maps test files from local Swift packages not listed directly in the Xcode project. Relative to the project root. |
| `source-commit`, `source-base` | Commit SHA or ref; base optional | Selects a commit or commit range. `source-commit` must match the checked-out commit; blank `source-base` uses its first parent. |
| `source-scope` | `changed` or `all`; commit mode defaults to `changed` | Chooses changed production Swift files or all source files. |
| `test-scope` | `changed`, `matching`, `changed-and-matching`, `affected-packages`, or `all`; commit mode defaults to `changed-and-matching` | Chooses changed or matching test files, affected package test targets, or the full test plan. |
| `test-file-suffix` | One suffix per line; default `Tests.swift` | Changes the filename rule used for matching tests to source files. |
| `mutation-source` | One relative path per line; blank means all discovered source | Limits mutation locations; matches repeatable `--mutation-source`. |
| `test-file`, `test-suite`, `test-name` | One selector per line; blank means no filter | Adds matching tests from any target included in the chosen scheme. Selectors combine with target-wide selections; you do not need to name their targets separately. |
| `operators` | Comma-separated operator names; blank means all available | Limits mutation types; matches `--operators`. |
| `operator-tier` | `experimental` (default) or `all` | Chooses the operator set. `conservative` and `default` are not available yet. |
| `workers` | Positive number; default `2` | Maximum number of concurrent mutants; matches `--workers`. |
| `xcodebuild-arg` | One `NAME=VALUE` per line | Extra Xcode build settings. |
| `full-xcode-test-build` | Defaults to `false` | Set to `true` to build the full Xcode scheme for scoped tests. |
| `cache-path` | Folder; blank uses default locations | Sets where reusable results and the CLI build cache are stored. |
| `no-cache`, `no-resume` | `true` or `false`; default `false` | Disables cache use or resuming prior results. |
| `no-suppressions`, `require-suppression-reason` | `true` or `false`; default `false` | Controls mutation suppression comments. |
| `build-timeout` | Seconds; default `600` | Maximum build time. |
| `baseline-timeout` | Seconds; default `300` | Maximum baseline test time. |
| `mutant-timeout` | Seconds; default `30` | Maximum time for one mutant's test command. |
| `minimum-score` | Number from `0` to `1` | Fails the job if the score is too low. |
| `baseline-report` | Path to an earlier `report.json` | Compares this run with an earlier report. |
| `maximum-score-drop` | Number from `0` to `1` | Maximum allowed score drop from the baseline report. |
| `fail-on-new-survivors` | `true` or `false`; default `false` | Fails if this run adds survivors compared with the baseline. |
| `maximum-integrity-warnings` | Zero or higher; default `0` | Maximum allowed integrity warnings. |
| `output` | Folder; default `.swift-mutation-testing` | Where reports are written; matches `--output`. |
| `artifact-name` | Default `swift-mutation-testing-report` | Uploaded report name; set a different name for each matrix job. |
| `tool-path` | Executable path; blank by default | Use a previously built CLI. Usually leave blank. |

The older input names `project-path`, `source`, `suite`, `test`, `test-targets`, `destination`, `parallelism`, and `output-path` remain accepted as aliases.

</details>

## What does a mutation run do?

The tool first runs the selected tests on the original code. If they fail, it stops. It then tries small code changes, one mutant at a time. If a test fails while a mutant is confirmed active, that mutant is killed. If tests pass, the tool finishes the selected test run to check whether the mutant survived or had no coverage.

By default, it mutates all discovered source files and runs all tests in the configured Swift package or Xcode scheme's test plan. `--mutation-source` limits which files are changed; it does not limit tests. In Xcode, repeat `--test-target` to add every test from multiple targets. Add any number of `--test-file`, `--test-suite`, and `--test-name` selectors to include only their matching tests from other targets in the same scheme. These selections are combined, and duplicate tests run once. A test file's owning target is discovered from Xcode project membership or the Swift package manifest. If it cannot be resolved, the tool errors rather than running an unrelated target.

Swift package dependencies are resolved from `Package.swift`. Local sibling packages are copied into the isolated sandbox with their relative paths preserved. Git dependencies use SwiftPM or Xcode resolution, including the manifest's version, exact version, tag, branch, or revision requirement. For Xcode projects, `--skip-package-resolution` skips the separate resolver step and disables automatic fetching during project builds. The selected test run then uses those same resolved packages. Source files and resources declared by package targets are copied with their package.

Mutation types include changing comparisons, Boolean values, logical and arithmetic operators, conditions, ternary branches, and standalone calls. See [Operators](Docs/OPERATORS.md) for supported Swift syntax and limits.

## What affects run time and cache reuse?

- Xcode simulator runs can use up to `--workers` workers (default: `2`). Swift package runs use parallel workers with Swift Testing; packages that use XCTest run serially.
- Xcode chooses its build job count unless you pass `--xcode-build-jobs`. The original build starts while the simulators boot. Mutant tests can run in parallel after startup.
- If an Xcode build fails only because build rules time out, mutest-swift retries once with one build job and the same DerivedData folder. The retry can reuse successful cache entries from the first attempt; other build errors are not retried.
- A source folder can contain hundreds of mutants. Xcode starts a test command for each one, so a 365-mutant run with one worker can take over an hour even if the selected tests take only seconds inside the simulator. The CLI shows the file and mutant counts and a time guide before mutant runs. For a quick local check, pass one or more specific files with `--mutation-source`; the selected tests stay the same.
- Before running mutants, Xcode tests must pass on the original code and on the compiled schema with all mutants inactive. If the inactive schema fails, the tool retries it, checks the original tests again, and identifies a smaller incompatible group only when the original tests stay stable. It stops without a score rather than reporting false kills.
- Xcode build files and downloaded dependencies stay in a temporary folder outside your copied source tree, so project-wide lint plugins do not scan that build folder. The folder is removed when the run finishes or fails. Your project's lint plugins still run normally.
- A verified test failure can end that mutant's run early. Survivors and mutants with no coverage finish the selected test scope.
- `--mutant-timeout` limits the complete test command for one mutant, including Xcode test-host startup. It defaults to 30 seconds. Increase it for slow integration tests—for example, `--mutant-timeout 90` for a WebSocket or WebRTC test target.
- If a generated schema does not compile, the tool uses compiler file locations to isolate the affected source candidates first. It only bisects the remaining batch when the compiler output cannot identify a source file. Invalid individual mutations are reported as unbuildable; they do not block unrelated mutants.
- JSON and Markdown reports include test counts and phase timings, such as build, baseline, mutant runs, and cleanup.
- The verdict cache can reuse completed mutants on later runs when the code, tests, selectors, build settings, toolchain, and tool version still match.
- `--no-cache` disables cache reads and writes. `--no-resume` ignores earlier results but still saves new ones.

## Releases

Maintainers publish releases from the **Signed release** workflow on `main`. Choose **Actions → Signed release → Run workflow** and enter the version without the `v` prefix, such as `0.3.9`. The workflow signs the version tag using the `release` environment, creates a source archive and SHA-256 checksum, publishes a GitHub Release, and attests the archive provenance.

After downloading the archive and checksum into the same directory, verify them with:

```sh
shasum -a 256 -c mutest-swift-v0.3.10.tar.gz.sha256
gh attestation verify mutest-swift-v0.3.10.tar.gz --owner j-khn
```

To verify the signed tag, fetch it and run `git tag -v v0.3.10` in a clone of the repository.

## License

Licensed under the [MIT License](LICENSE).

## Privacy information

`mutest-swift` has no telemetry and does not upload your source code, tests, or reports to its maintainers. Temporary project copies, build data, logs, reports, and cache files are written to the machine where it runs. SwiftPM and Xcode may access the network to resolve project dependencies, and the build scripts or tests you run may make their own network requests. When used in GitHub Actions, GitHub retains workflow logs according to your repository's Actions settings.
