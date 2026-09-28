#!/bin/bash
# MMP - build script
# Produces build/MMP.app from the Swift sources. No Xcode project required.
#
#   ./build.sh            build only
#   ./build.sh install    build + copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MMP"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> 1/5 生成应用图标"
mkdir -p "$BUILD_DIR"
if [ ! -f "Resources/AppIcon.icns" ]; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"
  swiftc -O -o "$BUILD_DIR/GenIcon" Tools/GenIcon.swift
  "$BUILD_DIR/GenIcon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "Resources/AppIcon.icns"
  echo "    Resources/AppIcon.icns"
else
  echo "    已存在，跳过"
fi

echo "==> 2/5 编译 Swift 源码"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
swiftc -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreServices \
  -framework UniformTypeIdentifiers \
  -framework ImageIO \
  -o "$MACOS/$APP_NAME" \
  Sources/MMP/*.swift

echo "==> 3/5 组装 .app bundle"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

echo "==> 4/5 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" || echo "    签名失败，仍可本地运行"

echo "==> 5/5 向 LaunchServices 注册"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -R -f "$PWD/$APP" || true
fi

echo ""
echo "构建完成: $PWD/$APP"

if [ "${1:-}" = "install" ]; then
  echo "==> 安装到 /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "已安装: /Applications/$APP_NAME.app"
fi
