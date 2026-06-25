#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0
SEARCH_TOOL=""

if command -v rg >/dev/null 2>&1; then
  SEARCH_TOOL="rg"
elif command -v grep >/dev/null 2>&1; then
  SEARCH_TOOL="grep"
else
  echo "::error::Neither rg nor grep is available; cannot run project hygiene checks"
  exit 127
fi

check_absent() {
  local description="$1"
  shift
  if [[ "$SEARCH_TOOL" == "rg" ]]; then
    if (cd "$ROOT" && rg -n "$@"); then
      echo "::error::$description"
      STATUS=1
    fi
  else
    local pattern="$1"
    shift
    local -a paths=()
    local -a include_globs=()
    local -a exclude_globs=()

    while (($#)); do
      case "$1" in
        --glob)
          shift
          if [[ "${1:-}" == !* ]]; then
            include_globs+=("$1")
          else
            exclude_globs+=("${1#!}")
          fi
          ;;
        --glob=*)
          local glob="${1#--glob=}"
          if [[ "$glob" == !* ]]; then
            include_globs+=("$glob")
          else
            exclude_globs+=("${glob#!}")
          fi
          ;;
        *)
          paths+=("$1")
          ;;
      esac
      shift
    done

    local -a fallback_args=("$pattern")
    fallback_args+=("${paths[@]}")
    fallback_args+=("--")
    if ((${#include_globs[@]})); then
      fallback_args+=("${include_globs[@]}")
    fi
    fallback_args+=("--")
    if ((${#exclude_globs[@]})); then
      fallback_args+=("${exclude_globs[@]}")
    fi

    if (cd "$ROOT" && fallback_grep "${fallback_args[@]}"); then
      echo "::error::$description"
      STATUS=1
    fi
  fi
}

fallback_grep() {
  local pattern="$1"
  shift
  local -a paths=()
  local -a include_globs=()
  local -a exclude_globs=()
  local target="paths"

  while (($#)); do
    if [[ "$1" == "--" ]]; then
      if [[ "$target" == "paths" ]]; then
        target="includes"
      else
        target="excludes"
      fi
      shift
      continue
    fi

    case "$target" in
      paths) paths+=("$1") ;;
      includes) include_globs+=("$1") ;;
      excludes) exclude_globs+=("$1") ;;
    esac
    shift
  done

  local matched=1
  while IFS= read -r -d '' file; do
    local include=true
    local normalized="${file#./}"

    if ((${#include_globs[@]})); then
      include=false
      for glob in "${include_globs[@]}"; do
        if [[ "$normalized" == $glob || "$(basename "$normalized")" == $glob ]]; then
          include=true
          break
        fi
      done
    fi

    if ((${#exclude_globs[@]})); then
      for glob in "${exclude_globs[@]}"; do
        if [[ "$normalized" == $glob || "$(basename "$normalized")" == $glob ]]; then
          include=false
          break
        fi
      done
    fi

    if [[ "$include" == true ]] && grep -nHE -- "$pattern" "$file"; then
      matched=0
    fi
  done < <(find "${paths[@]}" -type f -print0 2>/dev/null)

  return "$matched"
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
