# macOS Packaging

`来财 / Laicai` 的桌面主线已经切到原生 macOS app。旧 Electron / PyInstaller 打包链已下线，当前只保留 Native 构建入口。

## Build

```bash
cd native-macos
./build.sh
```

## Output

- app bundle: `native-macos/dist/Laicai.app`
- installer helper: `native-macos/dist/install_laicai.command`
- install notes: `native-macos/dist/INSTALL.txt`

## App Data

原生 app 使用固定产品数据目录：

- `~/Library/Application Support/Laicai`

这里保存连接器、会话、任务、审计、技能、工作流等本地数据。后续隐私和加密能力也以这个目录为边界推进。

## Installer Behavior

`install_laicai.command` 会优先安装到：

1. `/Applications/Laicai.app`
2. `~/Applications/Laicai.app`

安装脚本会复制当前构建出的原生 `.app`，保留产品 icon，并尝试做本地 ad-hoc signing。

## Verification

```bash
cd native-macos
./typecheck.sh
./build.sh
codesign --verify --deep --strict --verbose=2 dist/Laicai.app
open dist/Laicai.app
```

## Next Packaging Improvements

1. Developer ID signing
2. notarization
3. DMG packaging
4. first-run connector guide
