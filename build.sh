#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${PHOTO_BACKUP_APP_PATH:-$PWD/dist/照片增量备份.app}"
BUILD_ARCH="${PHOTO_BACKUP_ARCH:-$(uname -m)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/module-cache"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.samuel.photo-incremental-backup</string>
<key>CFBundleName</key><string>照片增量备份</string>
<key>CFBundleExecutable</key><string>PhotoBackup</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.2</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSUIElement</key><false/>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSPhotoLibraryUsageDescription</key><string>读取本机照片和视频，将原始资源增量复制到你选择的备份目录。应用不会修改或删除照片图库中的内容。</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -O -target "$BUILD_ARCH-apple-macosx13.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  Sources/Archive.swift Sources/Layout.swift Sources/ExportPolicy.swift Sources/DirectoryCopy.swift Sources/DirectoryCopyView.swift Sources/PhotoBackup.swift \
  -framework AppKit -framework SwiftUI -framework Photos -framework CryptoKit \
  -o "$APP/Contents/MacOS/PhotoBackup"
if [ -f "$PWD/Resources/AppIcon.icns" ]; then
  cp "$PWD/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
