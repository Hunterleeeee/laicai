#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WARN_LIMIT="${SWIFT_FILE_WARN_LIMIT:-2500}"
FAIL_LIMIT="${SWIFT_FILE_FAIL_LIMIT:-5500}"
STATUS=0

while IFS= read -r -d '' file; do
  lines="$(wc -l < "$file" | tr -d ' ')"
  rel="${file#$ROOT/}"
  if [ "$lines" -gt "$FAIL_LIMIT" ]; then
    echo "::error file=$rel::Swift file has $lines lines, above fail limit $FAIL_LIMIT"
    STATUS=1
  elif [ "$lines" -gt "$WARN_LIMIT" ]; then
    echo "::warning file=$rel::Swift file has $lines lines, above warning limit $WARN_LIMIT"
  fi
done < <(find "$ROOT/native-macos/Sources" "$ROOT/native-macos/Tests" -name '*.swift' -print0)

exit "$STATUS"
