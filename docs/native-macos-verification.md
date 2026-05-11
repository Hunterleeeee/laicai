# Native macOS Verification

## Current Local Blocker

This package requires Swift tools 5.9 and macOS 14:

```swift
// swift-tools-version: 5.9
.macOS(.v14)
```

The current machine is using Command Line Tools only:

```sh
xcode-select -p
# /Library/Developer/CommandLineTools

swift --version
# Apple Swift version 5.8.1
```

`swift test --package-path native-macos` currently fails before compiling the package:

```text
xcrun: error: unable to lookup item 'PlatformPath' from command line tools installation
```

## Fix

Install Xcode 15 or newer, then point developer tools at the full Xcode bundle:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcrun --sdk macosx --show-sdk-platform-path
swift --version
```

Expected:

- `xcrun --sdk macosx --show-sdk-platform-path` prints a platform path instead of an error.
- `swift --version` reports Swift 5.9 or newer.

Run the preflight first:

```sh
bash scripts/check_macos_toolchain.sh
```

Then run:

```sh
swift test --package-path native-macos
```

## Lightweight Checks

These checks do not require the full SwiftPM test run and should continue to pass before commits:

```sh
bash scripts/check_swift_file_sizes.sh
bash scripts/check_project_hygiene.sh
bash scripts/lint_swift.sh
```
