#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_FILE="$ROOT/native-macos/Package.swift"
STATUS=0

error() {
  echo "::error::$*"
  STATUS=1
}

info() {
  echo "==> $*"
}

version_ge() {
  local current="$1"
  local required="$2"
  local current_major current_minor required_major required_minor
  current_major="${current%%.*}"
  current_minor="${current#*.}"
  current_minor="${current_minor%%.*}"
  required_major="${required%%.*}"
  required_minor="${required#*.}"
  required_minor="${required_minor%%.*}"

  if [ "$current_major" -gt "$required_major" ]; then
    return 0
  fi
  if [ "$current_major" -eq "$required_major" ] && [ "$current_minor" -ge "$required_minor" ]; then
    return 0
  fi
  return 1
}

if ! command -v xcode-select >/dev/null 2>&1; then
  error "xcode-select is not available. Install Xcode 15 or newer."
else
  developer_dir="$(xcode-select -p 2>/dev/null || true)"
  if [ -z "$developer_dir" ]; then
    error "No active developer directory. Run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
  else
    info "Developer directory: $developer_dir"
    if [[ "$developer_dir" == "/Library/Developer/CommandLineTools"* ]]; then
      error "Active developer directory is Command Line Tools only. Use full Xcode 15+: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    fi
  fi
fi

if ! command -v swift >/dev/null 2>&1; then
  error "swift is not available. Install Xcode 15 or newer."
else
  swift_line="$(swift --version 2>/dev/null | head -n 1 || true)"
  info "Swift: ${swift_line:-unknown}"
  swift_version="$(printf '%s\n' "$swift_line" | sed -nE 's/.*Swift version ([0-9]+[.][0-9]+).*/\1/p')"
  required_swift="$(sed -nE 's|// swift-tools-version: ([0-9]+[.][0-9]+).*|\1|p' "$PACKAGE_FILE" | head -n 1)"
  if [ -n "$swift_version" ] && [ -n "$required_swift" ]; then
    if ! version_ge "$swift_version" "$required_swift"; then
      error "Swift $swift_version is older than Package.swift tools version $required_swift. Install Xcode 15 or newer."
    fi
  else
    error "Could not parse Swift version or Package.swift tools version."
  fi
fi

if ! command -v xcrun >/dev/null 2>&1; then
  error "xcrun is not available. Install Xcode 15 or newer."
else
  if sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>&1)"; then
    info "macOS SDK: $sdk_path"
  else
    error "Unable to resolve macOS SDK path: $sdk_path"
  fi

  if platform_path="$(xcrun --sdk macosx --show-sdk-platform-path 2>&1)"; then
    info "macOS platform: $platform_path"
  else
    error "Unable to resolve macOS platform path: $platform_path"
  fi
fi

if [ "$STATUS" -ne 0 ]; then
  cat <<'EOF'

Native macOS verification requires full Xcode 15 or newer:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  xcrun --sdk macosx --show-sdk-platform-path
  swift test --package-path native-macos
EOF
fi

exit "$STATUS"
