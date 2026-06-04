# Native macOS Verification

## Toolchain

This package requires Swift tools 5.9 and macOS 14:

```swift
// swift-tools-version: 5.9
.macOS(.v14)
```

Use full Xcode 15 or newer:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcrun --sdk macosx --show-sdk-platform-path
swift --version
```

Expected results:

- `xcrun --sdk macosx --show-sdk-platform-path` prints a platform path instead of an error.
- `swift --version` reports Swift 5.9 or newer.

Run the preflight:

```sh
bash scripts/check-macos-toolchain.sh
```

## Core Checks

```sh
bash scripts/check-project-hygiene.sh
bash scripts/check-swift-file-sizes.sh
swift test --package-path native-macos
```

The style lint entrypoint is also available:

```sh
bash scripts/lint-swift.sh
```

The current codebase still has existing SwiftLint/format debt, so use this as a cleanup aid rather than a required release gate.

## Local App Build

Build the app bundle and CLI:

```sh
LAICAI_ARCHS=arm64 bash native-macos/build.sh
```

Expected outputs:

```text
native-macos/dist/Laicai.app
native-macos/dist/laicai
native-macos/dist/install_laicai.command
native-macos/dist/INSTALL.txt
```

## DMG Packaging

Package and verify a local DMG:

```sh
LAICAI_ARCHS=arm64 bash native-macos/package-dmg.sh
```

Expected output:

```text
native-macos/dist/Laicai-<version>-<build>.dmg
```

The local DMG is a development build and is not Apple notarized by default.
