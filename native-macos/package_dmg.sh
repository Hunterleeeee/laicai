#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$SCRIPT_DIR/dist"
APP="$DIST/Laicai.app"
CLI="$DIST/laicai"
BUILD_SCRIPT="$SCRIPT_DIR/build.sh"

if [ "${LAICAI_SKIP_BUILD:-0}" != "1" ]; then
  bash "$BUILD_SCRIPT"
fi

if [ ! -d "$APP" ]; then
  echo "Missing app bundle: $APP" >&2
  echo "Run: bash $BUILD_SCRIPT" >&2
  exit 1
fi

if [ ! -x "$CLI" ]; then
  echo "Missing CLI binary: $CLI" >&2
  echo "Run: bash $BUILD_SCRIPT" >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required to package a DMG." >&2
  exit 1
fi

INFO_PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
SAFE_VERSION="$(printf '%s' "$VERSION" | tr -cs '[:alnum:]._' '-')"
SAFE_BUILD="$(printf '%s' "$BUILD_NUM" | tr -cs '[:alnum:]._' '-')"
DMG="$DIST/Laicai-${SAFE_VERSION}-${SAFE_BUILD}.dmg"
VOLUME_NAME="来财 $VERSION"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/laicai-dmg.XXXXXX")"
STAGE_ROOT="$STAGE/Laicai"

cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$STAGE_ROOT"
cp -R "$APP" "$STAGE_ROOT/Laicai.app"
cp "$CLI" "$STAGE_ROOT/laicai"
ln -s /Applications "$STAGE_ROOT/Applications"

if [ -f "$DIST/install_laicai.command" ]; then
  cp "$DIST/install_laicai.command" "$STAGE_ROOT/install_laicai.command"
  chmod +x "$STAGE_ROOT/install_laicai.command"
fi

if [ -f "$DIST/INSTALL.txt" ]; then
  cp "$DIST/INSTALL.txt" "$STAGE_ROOT/INSTALL.txt"
fi

cat > "$STAGE_ROOT/README.txt" << EOF
来财 Laicai

版本：$VERSION
构建：$BUILD_NUM

安装方式：
1. 将 Laicai.app 拖到 Applications。
2. 或双击 install_laicai.command 自动安装。
3. laicai 是命令行工具，可按需复制到 PATH 目录。

说明：
- 这是本地开发构建，默认未经过 Apple notarization。
- 首次打开后，请在设置里添加或选择模型连接器。
- 应用数据默认保存在 ~/Library/Application Support/Laicai。
EOF

rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_ROOT" \
  -ov \
  -format UDZO \
  "$DMG"

hdiutil verify "$DMG"

echo "DMG SUCCESS"
echo "  $DMG"
