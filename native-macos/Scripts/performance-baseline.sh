#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="$ROOT/native-macos"
PATH="/opt/homebrew/bin:$PATH"
export PATH

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf 'Laicai performance baseline\n'
printf 'timestamp=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'package=%s\n' "$PACKAGE"

/usr/bin/time -p swift build --package-path "$PACKAGE" >"$TMP_DIR/build.log" 2>"$TMP_DIR/build.time"
printf '\nbuild:\n'
cat "$TMP_DIR/build.time"

run_tests() {
    /usr/bin/time -p swift test --package-path "$PACKAGE" >"$TMP_DIR/test.log" 2>"$TMP_DIR/test.time"
}
run_tests
printf '\ntest:\n'
cat "$TMP_DIR/test.time"
grep -E 'Executed [0-9]+ tests, with [0-9]+ failures' "$TMP_DIR/test.log" | tail -1 || true
