#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

if command -v swift-format >/dev/null 2>&1; then
  swift-format lint --recursive "$ROOT/native-macos/Sources" "$ROOT/native-macos/Tests" || STATUS=1
else
  echo "swift-format not installed; skipping format lint"
fi

if command -v swiftlint >/dev/null 2>&1; then
  (cd "$ROOT" && swiftlint lint --config .swiftlint.yml) || STATUS=1
else
  echo "swiftlint not installed; skipping SwiftLint"
fi

exit "$STATUS"
