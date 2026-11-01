# mutest-swift

Mutation testing for Swift packages and Xcode apps. Use it from the command line or GitHub Actions.

## Quick Start

### 1. Run locally

Requirements: macOS 14 or newer, Xcode, and a Swift 6.4-compatible toolchain.

Clone the tool and enter its folder:

```sh
git clone https://github.com/jamilkhan55/mutest-swift.git
cd mutest-swift
```

Check the included sample package. This preflight checks project and test discovery; it does not run mutations:

```sh
swift run swift-mutation-testing validate --project Fixtures/SwiftPackage
```

Run mutation testing on that sample:

```sh
swift run swift-mutation-testing run \
  --project Fixtures/SwiftPackage \
  --project-kind swift-package \
  --operators relational,logical \
  --operator-tier experimental \
  --output /tmp/mutest-report
```

The first `swift run` builds the CLI. Reports are written to `/tmp/mutest-report`.

For your own Swift package, replace the sample path:

```sh
swift run swift-mutation-testing run \
  --project /path/to/MyPackage \
  --project-kind swift-package \
  --operator-tier experimental
```

With no test selector, the full test target runs. Add `--source Sources/Feature` to restrict where mutants are made; that does not restrict which tests run.

### 2. Run with GitHub Actions

`mutest-swift` is private. First allow access from your other private repositories in **mutest-swift → Settings → Actions → General → Access**. GitHub explains this setting [here](https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories).

In your app repository, create `.github/workflows/mutation.yml`:

```yaml
name: Mutation testing

on:
  workflow_dispatch:

jobs:
  mutation-testing:
    runs-on: [self-hosted, macos]
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with:
          path: .mutest-swift-cache
          key: mutest-swift-${{ runner.os }}-${{ github.ref_name }}-${{ github.sha }}
          restore-keys: |
            mutest-swift-${{ runner.os }}-${{ github.ref_name }}-
            mutest-swift-${{ runner.os }}-
      - name: Select Xcode toolchain
        run: |
          if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
            echo "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >> "$GITHUB_ENV"
          fi
          xcodebuild -version
          swift --version
          fingerprint="$( { xcode-select -p; xcodebuild -version; swift --version; } | shasum -a 256 | awk '{print $1}')"
          echo "MUTEST_TOOLCHAIN_FINGERPRINT=$fingerprint" >> "$GITHUB_ENV"
      - uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
        with:
          project-path: .
          project-kind: swift-package
          operator-tier: experimental
          cache-path: .mutest-swift-cache
```

Run it from the Actions tab with **Run workflow**. It tests the full target and uploads the report. Add `push:` or `pull_request:` under `on:` if you want it to run automatically.

### 3. For an Xcode app

Use the same CLI or Action, and set the Xcode project details. For the Action, replace its `uses` step with:

```yaml
- uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
  with:
    project-path: MyApp.xcodeproj
    project-kind: xcode-project
    scheme: MyApp
    test-target: MyAppTests
    destination: platform=iOS Simulator,name=iPhone 17,OS=latest
    xcodebuild-arg: |
      ARCHS=arm64
      ONLY_ACTIVE_ARCH=YES
    operator-tier: experimental
    parallelism: "2"
```

Replace the simulator name with one installed on your Mac. All seven operators are currently experimental.

For two iOS Simulator mutation workers from the CLI:

```sh
swift run swift-mutation-testing run \
  --project /path/to/MyApp.xcodeproj --project-kind xcode-project \
  --scheme MyApp --test-target MyAppTests \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --operator-tier experimental --parallelism 2
```

The tool creates two temporary simulators matching that destination, checks the baseline on each, and runs one mutant per worker. Each mutant uses all tests in `MyAppTests` unless you supply test selectors. Use `--parallelism 1` (or `parallelism: "1"` in the Action) for serial execution. Simulators are reused during the campaign and deleted afterward; the original simulator is used only as a template. Xcode workspaces use `--project-kind xcode-workspace`. Other destination platforms run serially and log the reason.

## Performance and cache

- With no test selector, every run uses the full configured test target. `--source` limits mutation locations only.
- A mutant run may stop after a selected test fails only after the engine verifies that mutant activated. Survivors and no-coverage mutants run the complete selected test scope.
- The JSON report includes phase timings for sandbox copying, discovery, input hashing, baseline, schema builds, mutant runs, isolated builds, and cleanup. The Markdown report shows the same timings.
- The run summary shows requested/active workers, simulator setup time, baseline tests per worker, baseline execution count, actual mutant test runs (including retries), generated mutants, source files, and total elapsed time. JSON stores these measurements in `execution`; mutant tests may stop after a verified kill, so their test-run count is separate from baseline test cases.
- Baseline test counts come from the native framework summaries. A parameterized Swift Testing declaration can contain multiple argument cases within one reported test.
- The optional verdict cache can resume completed mutants across GitHub Actions runs. The engine verifies source and test inputs, selectors, build settings, toolchain fingerprint, and engine version before reusing a verdict.
- Use `no-cache: true` on the Action for a clean speed benchmark. That disables both cache reads and writes.

## More

- CLI options: `swift run swift-mutation-testing help`.
- Tool tests: `swift test`.
- Operator details: [`Docs/OPERATORS.md`](Docs/OPERATORS.md).
- Shared rules and report schemas: [`mutest-core`](https://github.com/jamilkhan55/mutest-core).

## License

MIT. See [`LICENSE`](LICENSE).
