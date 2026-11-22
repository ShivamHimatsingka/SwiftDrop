#!/bin/bash
# Builds SwiftDrop.app (menu bar app + embedded Finder Share Extension) with swiftc.
# Usage: ./build.sh [--install]   (--install copies to /Applications and registers the extension)
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"
MIN="14.0"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
OUT="build"
APP="$OUT/SwiftDrop.app"
APPEX="$APP/Contents/PlugIns/SwiftDropShare.appex"
FLAGS=(-sdk "$SDK" -target "$ARCH-apple-macos$MIN" -swift-version 5 -O -whole-module-optimization)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$OUT/tmp"

echo "▸ Compiling SwiftDrop"
xcrun swiftc "${FLAGS[@]}" -module-name SwiftDrop \
  ../Core/Swift/*.swift Sources/App/*.swift \
  -o "$APP/Contents/MacOS/SwiftDrop"

echo "▸ Compiling SwiftDropShare.appex"
xcrun swiftc "${FLAGS[@]}" -module-name SwiftDropShare -application-extension -parse-as-library \
  ../Core/Swift/ControlAPI.swift ../Core/Swift/DeviceAvatar.swift Sources/Share/*.swift \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/SwiftDropShare"

cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/Share-Info.plist "$APPEX/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Rendering icon"
if [ ! -f "$OUT/AppIcon.icns" ] || [ Tools/make_icon.swift -nt "$OUT/AppIcon.icns" ]; then
  rm -rf "$OUT/tmp/AppIcon.iconset"
  xcrun swiftc -sdk "$SDK" Tools/make_icon.swift -o "$OUT/tmp/make_icon"
  "$OUT/tmp/make_icon" "$OUT/tmp/AppIcon.iconset"
  iconutil -c icns "$OUT/tmp/AppIcon.iconset" -o "$OUT/AppIcon.icns"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)"
codesign --force --sign - --entitlements Resources/Share.entitlements "$APPEX"
codesign --force --sign - --entitlements Resources/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x SwiftDrop 2>/dev/null || true
  rm -rf /Applications/SwiftDrop.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SwiftDrop.app
  pluginkit -a /Applications/SwiftDrop.app/Contents/PlugIns/SwiftDropShare.appex || true
  pluginkit -e use -i com.swiftdrop.app.share || true
  open /Applications/SwiftDrop.app
  echo "✓ Installed to /Applications and launched"
fi
