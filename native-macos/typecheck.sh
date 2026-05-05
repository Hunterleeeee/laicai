#!/bin/bash
set -e
BUILD=/tmp/laicai-native-build
SRC=/Users/lifenghe/Documents/troe_projects/harness/native-macos/Sources
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)

rm -rf $BUILD && mkdir -p $BUILD

echo "=== Domain ==="
swiftc \
  -target arm64-apple-macos13.3 \
  -sdk $SDK \
  -emit-module \
  -module-name LaicaiNativeDomain \
  -emit-module-path $BUILD/LaicaiNativeDomain.swiftmodule \
  -o $BUILD/LaicaiNativeDomain.o \
  $SRC/LaicaiNativeDomain/Models.swift

echo "=== Foundation ==="
swiftc \
  -target arm64-apple-macos13.3 \
  -sdk $SDK \
  -I $BUILD \
  -emit-module \
  -module-name LaicaiNativeFoundation \
  -emit-module-path $BUILD/LaicaiNativeFoundation.swiftmodule \
  -o $BUILD/LaicaiNativeFoundation.o \
  $SRC/LaicaiNativeFoundation/*.swift

echo "=== UI ==="
swiftc \
  -target arm64-apple-macos13.3 \
  -sdk $SDK \
  -I $BUILD \
  -emit-module \
  -module-name LaicaiNativeUI \
  -emit-module-path $BUILD/LaicaiNativeUI.swiftmodule \
  -o $BUILD/LaicaiNativeUI.o \
  $SRC/LaicaiNativeUI/*.swift

echo "=== App ==="
swiftc \
  -target arm64-apple-macos13.3 \
  -sdk $SDK \
  -I $BUILD \
  -parse-as-library \
  -typecheck \
  $SRC/LaicaiNativeApp/LaicaiNativeApp.swift

echo "ALL PASSED"
