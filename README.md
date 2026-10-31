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
      - name: Select Xcode toolchain
        run: |
          if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
            echo "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >> "$GITHUB_ENV"
          fi
          xcodebuild -version
          swift --version
      - uses: jamilkhan55/mutest-swift/.github/actions/run-mutation-testing@main
        with:
          project-path: .
          project-kind: swift-package
          operator-tier: experimental
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
    destination: platform=iOS Simulator,name=iPhone 17
    operator-tier: experimental
```

Replace the simulator name with one installed on your Mac. All seven operators are currently experimental.

## More

- CLI options: `swift run swift-mutation-testing help`.
- Tool tests: `swift test`.
- Operator details: [`Docs/OPERATORS.md`](Docs/OPERATORS.md).
- Shared rules and report schemas: [`mutest-core`](https://github.com/jamilkhan55/mutest-core).

## License

MIT. See [`LICENSE`](LICENSE).
