#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
RELEASE_ROOT="$PWD/.build/dmg-stage"
APP="$RELEASE_ROOT/照片增量备份.app"
mkdir -p "$RELEASE_ROOT" "$PWD/Resources" "$PWD/.build/module-cache" "$PWD/dist"
if [ -e "$APP" ]; then
  printf '%s\n' '已有打包暂存应用，请先将 .build/dmg-stage 改名保存，再重试。' >&2
  exit 1
fi
xcrun swiftc -module-cache-path "$PWD/.build/module-cache" Tools/MakeIcon.swift -o .build/make-icon
.build/make-icon "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$PWD/Resources/AppIcon.icns"
PHOTO_BACKUP_APP_PATH="$APP" PHOTO_BACKUP_ARCH=arm64 bash build.sh
ln -s /Applications "$RELEASE_ROOT/Applications"
cp "$PWD/发行安装说明.txt" "$RELEASE_ROOT/安装与使用说明.txt"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$PWD/dist/照片增量备份-${VERSION}-AppleSilicon.dmg"
if [ -e "$DMG" ]; then
  printf '%s\n' "镜像已存在，未覆盖：$DMG" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
lipo -verify_arch arm64 "$APP/Contents/MacOS/PhotoBackup"
hdiutil create -volname "照片增量备份 ${VERSION}" -srcfolder "$RELEASE_ROOT" \
  -format UDZO -imagekey zlib-level=9 "$DMG"
hdiutil verify "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
printf '%s\n' "$DMG"
