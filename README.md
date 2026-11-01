# mutest-swift

Mutation testing for Swift packages and Xcode apps. Use it from the command line or GitHub Actions.

## Quick Start

### 1. Run locally

Requirements: macOS 14 or newer, Xcode, Python 3, and a Swift 6.4-compatible toolchain.

Clone the tool, enter its folder, and point `./run` at your codebase:

```sh
git clone https://github.com/jamilkhan55/mutest-swift.git
cd mutest-swift
./run /path/to/your/project
```

The first run builds the command line tool. Swift packages run directly. For an Xcode project or workspace, `./run` lists the schemes, test targets, and installed iPhone simulators, then asks you to choose. Press Enter to choose the first scheme or simulator. To launch it from your project folder without giving a project path, use the script from your cloned tool repository:

```sh
cd /path/to/your/project
/path/to/mutest-swift/run
```

For this sample project, choose **MutationTest** to run the combined app test target, including tests from the local packages. Choose a `Checkout...` scheme to run only that package's tests. In the scheme menu, press Enter to choose the first option.

Pass choices as flags to skip the prompts. `--target` selects the Xcode test target; `--target-file` and `--target-tests` select tests. `--source` limits mutation locations, while tests still run across the full configured target unless test selectors are supplied.

```sh
./run /path/to/MyApp.xcodeproj \
  --scheme MyApp \
  --target MyAppTests \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --parallelism 2
```

Useful options:

```sh
./run --help
./run /path/to/project --validate
./run /path/to/project --parallelization 2 --target-file CheckoutTests.swift --target-tests checkoutTotal
./run /path/to/project --source Sources/Checkout
```

Reports are written to `.swift-mutation-testing/` inside the project by default. The tool mutates a temporary copy, leaving your source files unchanged. Xcode simulator builds use the Mac's architecture by default. To override it, pass settings such as `--xcodebuild-arg ARCHS=arm64 --xcodebuild-arg ONLY_ACTIVE_ARCH=YES`.

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
      - name: Build mutest-swift CLI
        id: mutest-swift-cli
        uses: jamilkhan55/mutest-swift/.github/actions/build-cli@main
        with:
          cache-path: .mutest-swift-cache
      - uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
        with:
          tool-path: ${{ steps.mutest-swift-cli.outputs.tool-path }}
          project-path: .
          project-kind: swift-package
          operator-tier: experimental
          cache-path: .mutest-swift-cache
```

Run it from the Actions tab with **Run workflow**. It tests the full target and uploads the report. Add `push:` or `pull_request:` under `on:` if you want it to run automatically.

### 3. For an Xcode app

Use the same CLI or Actions, and set the Xcode project details. Build the CLI before the mutation step so the mutation timing excludes compilation:

```yaml
- name: Build mutest-swift CLI
  id: mutest-swift-cli
  uses: jamilkhan55/mutest-swift/.github/actions/build-cli@main
  with:
    cache-path: .mutest-swift-cache
- name: Run mutation testing
  uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
  with:
    tool-path: ${{ steps.mutest-swift-cli.outputs.tool-path }}
    project-path: MyApp.xcodeproj
    project-kind: xcode-project
    scheme: MyApp
    test-target: MyAppTests
    destination: platform=iOS Simulator,name=iPhone 17,OS=latest
    operator-tier: experimental
    parallelism: "2"
```

Replace the simulator name with one installed on your Mac. All seven operators are currently experimental.

For two iOS Simulator mutation workers from the CLI:

```sh
./run /path/to/MyApp.xcodeproj \
  --scheme MyApp --target MyAppTests \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --parallelism 2
```

The tool creates two temporary simulators matching that destination, checks the baseline on each, and runs one mutant per worker. Each mutant uses all tests in `MyAppTests` unless you supply test selectors. Use `--parallelism 1` (or `parallelism: "1"` in the Action) for serial execution. Simulators are reused during the campaign and deleted afterward; the original simulator is used only as a template. Xcode workspaces use `--project-kind xcode-workspace`. Other destination platforms run serially and log the reason.

A shut-down template is cloned to reuse its completed simulator setup. A booted template uses freshly created matching devices so its running state is preserved. Small campaigns can spend more time preparing simulators than they save through parallel testing; compare worker counts using the reported total time.

## Performance and cache

- With no test selector, every run uses the full configured test target. `--source` limits mutation locations only.
- A mutant run may stop after a selected test fails only after the engine verifies that mutant activated. Survivors and no-coverage mutants run the complete selected test scope.
- The JSON report includes phase timings for sandbox copying, discovery, input hashing, baseline, schema builds, mutant runs, isolated builds, and cleanup. The Markdown report shows the same timings.
- The run summary shows requested/active workers, simulator setup time, baseline tests per worker, baseline execution count, actual mutant test runs (including retries), generated mutants, source files, and total elapsed time. JSON stores these measurements in `execution`; mutant tests may stop after a verified kill, so their test-run count is separate from baseline test cases.
- Baseline test counts come from the native framework summaries. A parameterized Swift Testing declaration can contain multiple argument cases within one reported test.
- The optional verdict cache can resume completed mutants across GitHub Actions runs. The engine verifies source and test inputs, selectors, build settings, toolchain fingerprint, and engine version before reusing a verdict.
- Use `no-cache: true` on the Action for a clean speed benchmark. That disables both cache reads and writes.

## More

- CLI options: `./run --help`.
- Tool tests: `swift test`.
- Operator details: [`Docs/OPERATORS.md`](Docs/OPERATORS.md).
- Shared rules and report schemas: [`mutest-core`](https://github.com/jamilkhan55/mutest-core).

## License

MIT. See [`LICENSE`](LICENSE).
