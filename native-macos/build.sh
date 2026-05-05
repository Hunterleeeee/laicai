#!/bin/bash
set -e
B=/tmp/laicai-native-build
ROOT=/Users/lifenghe/Documents/troe_projects/harness
NATIVE_ROOT=$ROOT/native-macos
S=$NATIVE_ROOT/Sources
K=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
DIST=$NATIVE_ROOT/dist
APP=$DIST/Laicai.app
ICON=$ROOT/assets/laicai.icns

# Auto version: YYYY.MM.DD for display, HHmm for build number
VER=$(date +%Y.%-m.%-d)
BUILD_NUM=$(date +%-H%M)
echo "=== Version $VER (build $BUILD_NUM) ==="

rm -rf $B && mkdir -p $B/src
rm -rf "$APP"
mkdir -p "$DIST"

echo "=== Prepare flat sources (strip cross-module imports) ==="
while IFS= read -r f; do
  bn=$(basename "$f")
  sed -E 's/^import LaicaiNative(Domain|Foundation|UI)$/\/\/ flat-build/' "$f" > "$B/src/$bn"
done < <(find "$S" -type f -name '*.swift' -not -path '*/LaicaiNativeCLI/*' | sort)

echo "=== Compile App ==="
swiftc -target arm64-apple-macos13.3 -sdk $K \
  -parse-as-library \
  -o $B/LaicaiNativeApp \
  $B/src/*.swift \
  -framework SwiftUI -framework AppKit -framework Foundation -framework WebKit

echo "=== Compile CLI ==="
# CLI shares all Foundation/Domain code, excludes UI/App entry, adds CLI entry
CLI_SRC=$NATIVE_ROOT/Sources/LaicaiNativeCLI
mkdir -p $B/cli_src
# Copy non-UI, non-App sources for CLI
# Exclude any file that imports SwiftUI, AppKit, or is the app entry point
for f in $B/src/*.swift; do
  bn=$(basename "$f")
  # Always skip explicit UI/App files
  case "$bn" in
    LaicaiNativeApp.swift|AppStore.swift|HeadlessRunner.swift|SampleData.swift) continue ;;
  esac
  # Skip any file that imports SwiftUI or AppKit (UI file)
  if grep -qE '^import (SwiftUI|AppKit)' "$f"; then
    continue
  fi
  cp "$f" "$B/cli_src/$bn"
done
# Add CLI source
sed -E 's/^import LaicaiNative(Domain|Foundation|UI)$/\/\/ flat-build/' "$CLI_SRC/LaicaiCLI.swift" > "$B/cli_src/LaicaiCLI.swift"
# CLI needs a @main or top-level entry; add shim
cat > "$B/cli_src/CLIMain.swift" << 'CLIMAIN'
// CLI entry point
@main struct LaicaiCLIEntry {
    static func main() async {
        await LaicaiCLI.main()
    }
}
CLIMAIN

# Stubs for types that live in excluded UI/AppKit files
cat > "$B/cli_src/CLIStubs.swift" << 'STUBS'
import Foundation
// Stub for NotificationManager (lives in BackgroundIntelligence which imports AppKit)
final class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()
    func post(title: String, body: String) {}
    func requestPermission() {}
}
STUBS
swiftc -target arm64-apple-macos13.3 -sdk $K \
  -parse-as-library \
  -o $B/laicai \
  $B/cli_src/*.swift \
  -framework Foundation -framework WebKit \
  2>/dev/null || echo "  (CLI build skipped — UI-free compilation needs refinement)"

echo "=== Create .app bundle ==="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp $B/LaicaiNativeApp "$APP/Contents/MacOS/"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/laicai.icns"
fi

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LaicaiNativeApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.laicai.app</string>
    <key>CFBundleName</key>
    <string>来财</string>
    <key>CFBundleDisplayName</key>
    <string>来财</string>
    <key>CFBundleIconFile</key>
    <string>laicai</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VER}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.3</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Copy CLI binary if built
if [ -f "$B/laicai" ]; then
  cp "$B/laicai" "$DIST/laicai"
  chmod +x "$DIST/laicai"
fi

if [ -f "$ROOT/packaging/macos/install_laicai.command" ]; then
  cp "$ROOT/packaging/macos/install_laicai.command" "$DIST/install_laicai.command"
  chmod +x "$DIST/install_laicai.command"
fi

cat > "$DIST/INSTALL.txt" << 'EOF'
来财原生版安装说明

这是本地开发构建，不是 Apple notarized 的正式发行版。

推荐安装方式：

1. 打开这个目录。
2. 双击 `install_laicai.command`。
3. 脚本会优先安装到 `/Applications/Laicai.app`。
4. 如果 `/Applications` 不可写，会自动退到 `~/Applications/Laicai.app`。
5. 第一次打开后，请先到设置里添加或选择模型。

应用数据默认保存在：

`~/Library/Application Support/Laicai`

如果系统拦截打开，请到：

系统设置 -> 隐私与安全性 -> 仍要打开
EOF

echo "BUILD SUCCESS — v$VER (build $BUILD_NUM)"
echo "  App:       $APP"
echo "  CLI:       $DIST/laicai"
echo "  Installer: $DIST/install_laicai.command"
ls -la "$B/LaicaiNativeApp"
[ -f "$B/laicai" ] && ls -la "$B/laicai"
