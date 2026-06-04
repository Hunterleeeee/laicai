#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0

check_absent() {
  local description="$1"
  shift
  if (cd "$ROOT" && rg -n "$@"); then
    echo "::error::$description"
    STATUS=1
  fi
}

check_absent \
  "Hardcoded local harness paths are not allowed" \
  '/Users/lifenghe/Documents/troe_projects/harness' \
  README.md docs native-macos skills scripts .github \
  --glob '!scripts/check-project-hygiene.sh' \
  --glob '!native-macos/dist/**'

check_absent \
  "Do not use or recommend git add -A; stage explicit paths with git add -- <paths>" \
  'git add -A' \
  native-macos/Sources native-macos/Tests docs README.md scripts .github \
  --glob '*.swift' --glob '*.md' --glob '*.sh' --glob '*.py' --glob '*.yml' \
  --glob '!check-project-hygiene.sh'

check_absent \
  "Use kebab-case names for repository scripts and packaging commands" \
  'check_macos_toolchain|check_project_hygiene|check_swift_file_sizes|lint_swift|validate_skills|package_dmg|native-macos-verification' \
  README.md CONTRIBUTING.md docs scripts .github native-macos/Tests \
  --glob '*.md' --glob '*.sh' --glob '*.py' --glob '*.yml' --glob '*.swift' \
  --glob '!check-project-hygiene.sh'

check_absent \
  "Bundled skills must use the canonical tools + steps schema" \
  '"(promptFile|schema_version|commandSample|parameters|arguments|requires)"' \
  skills \
  --glob 'skill.json'

check_absent \
  "Legacy macOS 13.3 deployment target should not reappear" \
  'macos13\.3|LSMinimumSystemVersion</key>[[:space:]]*<string>13\.3' \
  README.md docs native-macos \
  --glob '!native-macos/dist/**'

exit "$STATUS"
