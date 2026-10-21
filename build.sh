#!/bin/zsh
# build.sh - compile Headroom.app and its widget (universal: Apple silicon + Intel).
#
#   ./build.sh             build into ./build/Headroom.app
#   ./build.sh --install   also install to ~/Applications and start it
#
# Needs Xcode or the Command Line Tools to build; the built app needs neither.

set -euo pipefail

SRC=${0:A:h}
BUILD="$SRC/build"
APP="$BUILD/Headroom.app"
EXT="$APP/Contents/PlugIns/HeadroomWidget.appex"
DEST="$HOME/Applications/Headroom.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS"

for arch in arm64 x86_64; do
  target="$arch-apple-macos14.0"
  swiftc -O -swift-version 5 -parse-as-library -target "$target" \
    -o "$BUILD/Headroom-$arch" "$SRC"/Sources/Shared/*.swift "$SRC"/Sources/App/*.swift
  # A widget must start at _NSExtensionMain, the classic app-extension entry point.
  # Left to its default, `@main WidgetBundle` boots through ExtensionKit instead,
  # which crashes when macOS launches the widget, so it never shows in the gallery.
  swiftc -O -swift-version 5 -parse-as-library -application-extension -target "$target" \
    -module-name HeadroomWidget -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$BUILD/HeadroomWidget-$arch" "$SRC"/Sources/Shared/*.swift "$SRC"/Sources/Widget/*.swift
done
lipo -create -output "$APP/Contents/MacOS/Headroom" "$BUILD"/Headroom-arm64 "$BUILD"/Headroom-x86_64
lipo -create -output "$EXT/Contents/MacOS/HeadroomWidget" "$BUILD"/HeadroomWidget-arm64 "$BUILD"/HeadroomWidget-x86_64

cp "$SRC/Support/App-Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Support/Widget-Info.plist" "$EXT/Contents/Info.plist"
cp "$SRC/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A personal badge for the widget's corner, if you keep one in Support/Local (not committed).
if [[ -f "$SRC/Support/Local/Badge.svg" ]]; then
  mkdir -p "$EXT/Contents/Resources"
  cp "$SRC/Support/Local/Badge.svg" "$APP/Contents/Resources/Badge.svg"
  cp "$SRC/Support/Local/Badge.svg" "$EXT/Contents/Resources/Badge.svg"
fi

# Sign inside out: the widget with its sandbox, then the app around it.
codesign --force --sign - --entitlements "$SRC/Support/Widget.entitlements" "$EXT"
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Headroom"' 2>/dev/null || true
  mkdir -p "${DEST:h}"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  # Drop the build copy, or Spotlight lists Headroom twice.
  rm -rf "$BUILD"
  open "$DEST"
  echo "installed $DEST"
fi
