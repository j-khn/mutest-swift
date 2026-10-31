# mutest-swift

Mutation testing for Swift packages and Xcode apps. `mutest-swift` is a Swift CLI and GitHub Action implementing the [`mutest-core`](https://github.com/jamilkhan55/mutest-core) contract.

## Requirements

- macOS 14 or newer.
- Xcode with a Swift 6.4-compatible toolchain (SwiftSyntax 604.0.0).

## Quick start

Clone the tool and run the included SwiftPM sample. The first `swift run` builds the CLI and resolves its dependencies.

```sh
git clone https://github.com/jamilkhan55/mutest-swift.git
cd mutest-swift
swift run swift-mutation-testing run \
  --project Fixtures/SwiftPackage \
  --project-kind swift-package \
  --operators relational,logical \
  --operator-tier experimental \
  --output /tmp/mutest-report
```

The CLI prints the mutation score and writes `report.md`, `report.json`, and `stryker.json` to `/tmp/mutest-report`.

## Use it on your project

From the `mutest-swift` checkout, point `--project` at your package. With no test selector, it runs the full test target.

```sh
swift run swift-mutation-testing run \
  --project /path/to/MyPackage \
  --project-kind swift-package \
  --operator-tier experimental
```

To restrict mutation locations, add `--source Sources/CheckoutDomain`. To select tests, add `--test-file`, `--suite`, or `--test`. Source selection does not narrow the tests, so you can still check for ripple effects across the full suite.

For an Xcode app, provide its scheme and test target:

```sh
swift run swift-mutation-testing run \
  --project /path/to/MyApp.xcodeproj \
  --project-kind xcode-project \
  --scheme MyApp \
  --test-target MyAppTests \
  --destination 'platform=iOS Simulator,name=iPhone 17' \
  --operator-tier experimental
```

Use a simulator installed on your Mac. The included Xcode sample is `Fixtures/XcodeApp/MutationFixture.xcodeproj`.

## GitHub Actions

The composite action runs the CLI, adds the Markdown report to the job summary, and uploads the reports as an artifact. Your workflow checks out your app; you do not need to clone `mutest-swift` or run `swift test` first.

`mutest-swift` is private. To use it from another private repository owned by `jamilkhan55`, allow access in **mutest-swift → Settings → Actions → General → Access**. See [GitHub's private action instructions](https://docs.github.com/en/actions/how-tos/reuse-automations/share-across-private-repositories).

Add `.github/workflows/mutation.yml` to your app repository:

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
        run: |
          set -euo pipefail
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

This runs the full package and test target when manually started or on the weekday schedule. For an Xcode app, set `project-kind: xcode-project` and provide `scheme`, `test-target`, and `destination`.

## More

- Run the tool's own tests: `swift test`.
- See all CLI options: `swift run swift-mutation-testing help`.
- Operator syntax and tier policy: [`Docs/OPERATORS.md`](Docs/OPERATORS.md).

All seven operators are currently experimental. See [`mutest-core`](https://github.com/jamilkhan55/mutest-core) for the language-neutral rules and schemas.

## License

MIT. See [`LICENSE`](LICENSE).
