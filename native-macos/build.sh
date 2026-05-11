#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$SCRIPT_DIR"
ROOT="$(cd "$NATIVE_ROOT/.." && pwd)"
B="${TMPDIR:-/tmp}/laicai-native-build"
S="$NATIVE_ROOT/Sources"
K="$(xcrun --sdk macosx --show-sdk-path)"
DIST="$NATIVE_ROOT/dist"
APP="$DIST/Laicai.app"
ICON="$ROOT/assets/laicai.icns"
MIN_MACOS_VERSION="${LAICAI_MIN_MACOS_VERSION:-14.0}"
ARCHS="${LAICAI_ARCHS:-arm64 x86_64}"

# Auto version: YYYY.MM.DD for display, HHmm for build number
VER=$(date +%Y.%-m.%-d)
BUILD_NUM=$(date +%-H%M)
echo "=== Version $VER (build $BUILD_NUM) ==="

rm -rf "$B" && mkdir -p "$B/src"
rm -rf "$APP"
mkdir -p "$DIST"

echo "=== Prepare flat sources (strip cross-module imports) ==="
while IFS= read -r f; do
  bn=$(basename "$f")
  sed -E 's/^import LaicaiNative(Domain|Foundation|UI)$/\/\/ flat-build/' "$f" > "$B/src/$bn"
done < <(find "$S" -type f -name '*.swift' -not -path '*/LaicaiNativeCLI/*' | sort)

echo "=== Compile App ==="
APP_BINARIES=()
for ARCH in $ARCHS; do
  echo "  arch: $ARCH"
  swiftc -target "$ARCH-apple-macos$MIN_MACOS_VERSION" -sdk "$K" \
    -parse-as-library \
    -o "$B/LaicaiNativeApp-$ARCH" \
    "$B"/src/*.swift \
    -framework SwiftUI -framework AppKit -framework Foundation -framework WebKit
  APP_BINARIES+=("$B/LaicaiNativeApp-$ARCH")
done
if [ "${#APP_BINARIES[@]}" -gt 1 ]; then
  lipo -create "${APP_BINARIES[@]}" -output "$B/LaicaiNativeApp"
else
  cp "${APP_BINARIES[0]}" "$B/LaicaiNativeApp"
fi

echo "=== Compile CLI ==="
# CLI shares all Foundation/Domain code, excludes UI/App entry, adds CLI entry
CLI_SRC="$NATIVE_ROOT/Sources/LaicaiNativeCLI"
mkdir -p "$B/cli_src"
# Copy non-UI, non-App sources for CLI
# Exclude any file that imports SwiftUI, AppKit, or is the app entry point
for f in $B/src/*.swift; do
  bn=$(basename "$f")
  # Always skip explicit UI/App files
  case "$bn" in
    LaicaiNativeApp.swift|AppStore.swift|AppStateBootstrap.swift|TaskStateHelpers.swift|RuntimeHelpers.swift|HeadlessRunner.swift|SampleData.swift|BackgroundIntelligence.swift) continue ;;
  esac
  # Skip any file that imports SwiftUI or AppKit (UI file)
  if grep -qE '^import (SwiftUI|AppKit)' "$f"; then
    continue
  fi
  cp "$f" "$B/cli_src/$bn"
done
# Add CLI source
sed -E 's/^import LaicaiNative(Domain|Foundation|UI)$/\/\/ flat-build/' "$CLI_SRC/LaicaiCLI.swift" > "$B/cli_src/LaicaiCLI.swift"
cp "$CLI_SRC/CLIMain.swift" "$B/cli_src/CLIMain.swift"

# Stubs for types that live in excluded UI/AppKit files
cat > "$B/cli_src/CLIStubs.swift" << 'STUBS'
import Foundation
// Stub for NotificationManager (lives in BackgroundIntelligence which imports AppKit)
final class NotificationManager {
    static let shared = NotificationManager()
    func post(title: String, body: String) {}
    func requestPermission() {}
}
STUBS
CLI_BINARIES=()
for ARCH in $ARCHS; do
  echo "  arch: $ARCH"
  swiftc -target "$ARCH-apple-macos$MIN_MACOS_VERSION" -sdk "$K" \
    -parse-as-library \
    -D LAICAI_CLI \
    -o "$B/laicai-$ARCH" \
    "$B"/cli_src/*.swift \
    -framework Foundation -framework WebKit
  CLI_BINARIES+=("$B/laicai-$ARCH")
done
if [ "${#CLI_BINARIES[@]}" -gt 1 ]; then
  lipo -create "${CLI_BINARIES[@]}" -output "$B/laicai"
else
  cp "${CLI_BINARIES[0]}" "$B/laicai"
fi

echo "=== Create .app bundle ==="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$B/LaicaiNativeApp" "$APP/Contents/MacOS/"
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
    <string>${MIN_MACOS_VERSION}</string>
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

cp "$B/laicai" "$DIST/laicai"
chmod +x "$DIST/laicai"

cat > "$DIST/install_laicai.command" << 'INSTALLER'
#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/Laicai.app"
if [ ! -d "$SRC" ]; then
  echo "未找到 Laicai.app：$SRC"
  exit 1
fi
DEST="/Applications/Laicai.app"
if [ ! -w "/Applications" ]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/Laicai.app"
fi
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "已安装到 $DEST"
INSTALLER
chmod +x "$DIST/install_laicai.command"

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
ls -la "$B/laicai"
