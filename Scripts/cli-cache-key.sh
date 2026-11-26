#!/usr/bin/env bash
set -euo pipefail

# Both composite actions use this fingerprint. The executable may be cached on
# self-hosted runners, so keep toolchains and operating systems separate.
engine_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v shasum >/dev/null 2>&1; then
  hash() { shasum -a 256 | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  hash() { sha256sum | awk '{print $1}'; }
else
  echo "A SHA-256 utility (shasum or sha256sum) is required for CLI caching." >&2
  exit 1
fi

toolchain_fingerprint="$({
  uname -sm
  if [[ -r /etc/os-release ]]; then cat /etc/os-release; fi
  if command -v xcode-select >/dev/null 2>&1; then xcode-select -p; fi
  command -v swift
  swift --version
} | hash)"
package_fingerprint="$(cd "$engine_path" && {
  for file in Package.swift Package.resolved; do
    printf '%s ' "$file"
    hash < "$file"
  done
  find Sources -type f -name '*.swift' -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    hash < "$file"
  done
} | hash)"
printf '%s-%s\n' "$toolchain_fingerprint" "$package_fingerprint"
