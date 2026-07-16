#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0
FILES=()

if (($#)); then
  for file in "$@"; do
    [[ "$file" == *.swift && -f "$ROOT/$file" ]] && FILES+=("$ROOT/$file")
  done
elif [[ -n "${SWIFT_LINT_BASE:-}" ]] && git -C "$ROOT" rev-parse --verify "$SWIFT_LINT_BASE^{commit}" >/dev/null 2>&1; then
  while IFS= read -r -d '' file; do
    [[ -f "$ROOT/$file" ]] && FILES+=("$ROOT/$file")
  done < <(git -C "$ROOT" diff --name-only --diff-filter=ACMR -z "$SWIFT_LINT_BASE" -- 'native-macos/**/*.swift')
  while IFS= read -r -d '' file; do
    [[ -f "$ROOT/$file" ]] && FILES+=("$ROOT/$file")
  done < <(git -C "$ROOT" ls-files --others --exclude-standard -z -- 'native-macos/**/*.swift')
else
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <(find "$ROOT/native-macos/Sources" "$ROOT/native-macos/Tests" -name '*.swift' -print0)
fi

if ((${#FILES[@]} == 0)); then
  echo "No changed Swift files to lint"
  exit 0
fi

if xcrun --find swift-format >/dev/null 2>&1; then
  xcrun swift-format lint --strict "${FILES[@]}" || STATUS=1
elif command -v swift-format >/dev/null 2>&1; then
  swift-format lint --strict "${FILES[@]}" || STATUS=1
else
  echo "::error::swift-format is unavailable"
  STATUS=1
fi

if command -v swiftlint >/dev/null 2>&1; then
  (cd "$ROOT" && swiftlint lint --config .swiftlint.yml "${FILES[@]}") || STATUS=1
else
  echo "SwiftLint is not installed; swift-format checks still enforced"
fi

exit "$STATUS"
