# Changelog

## Unreleased

- Reuse the original Xcode build workspace for isolated mutants to avoid another cold build, while keeping source-relative fixtures stable during their tests.
- Add opt-in compiled Xcode caching, shared scheme narrowing, test plan selection, configurable build jobs and Xcode timing summaries.
- Report original, schema and isolated builds separately from unit test commands, with timing for each retry.
- Cover comment and blank-line edits with a change selection regression test.

## v0.3.9 — 2026-11-28

- Use generic wording for build rule timeout retry messages and logs.

## v0.3.8 — 2026-11-28

- Retry Xcode builds once with one build job when the only reported errors are build rule timeouts. The retry uses the same DerivedData folder so successful cache entries can be reused.

## v0.3.7 — 2026-11-27

- Document a pull request workflow that builds and runs mutest-swift directly from a release tag, without using the mutest-swift GitHub Action.
- Skip successfully with a clear report when commit-based test selection finds no test files, instead of failing the workflow.
- Let Xcode runs reuse existing Swift package checkouts and caches without resolving or fetching packages.

## v0.3.6 — 2026-11-27

### Added

- Add `--test-scope affected-packages` and the matching GitHub Action input. With changed source selection, this runs all test targets declared by the Swift packages containing changed source files. Xcode package test targets must be included in the chosen scheme's test plan.
- Add CentOS Stream 9 and 10 integration coverage for package-based test selection, plus manual dispatch for macOS tests.

### Improved

- Report a clear error when changed source is outside a Swift package or affected packages have duplicate test target names, instead of selecting an ambiguous test target.
- Document package-based test selection and align the CLI and report version with the release.
