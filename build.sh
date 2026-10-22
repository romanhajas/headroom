#!/bin/zsh
# build.sh - compile Headroom.app and its widget (universal: Apple silicon + Intel).
#
#   ./build.sh             build into ./build/Headroom.app
#   ./build.sh --install   also install to ~/Applications and start it
#   ./build.sh --release   sign, notarize and zip it as ./build/Headroom.zip
#
# Signing is ad-hoc unless .signing.env (git-ignored) says otherwise, e.g.
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="notary"   # saved by: xcrun notarytool store-credentials notary ...
#
# Needs Xcode or the Command Line Tools to build; the built app needs neither.

set -euo pipefail

SRC=${0:A:h}
BUILD="$SRC/build"
APP="$BUILD/Headroom.app"
EXT="$APP/Contents/PlugIns/HeadroomWidget.appex"
DEST="$HOME/Applications/Headroom.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

INSTALL=0 RELEASE=0
for arg in "$@"; do
  case $arg in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

SIGN_IDENTITY=- NOTARY_PROFILE= NOTARY_KEYCHAIN=
[[ -f "$SRC/.signing.env" ]] && source "$SRC/.signing.env"
# The notarytool profile lives in the login keychain unless NOTARY_KEYCHAIN names another (CI).
NOTARY=(--keychain-profile "$NOTARY_PROFILE")
[[ -n "$NOTARY_KEYCHAIN" ]] && NOTARY+=(--keychain "$NOTARY_KEYCHAIN")
if (( RELEASE )) && [[ "$SIGN_IDENTITY" == "-" || -z "$NOTARY_PROFILE" ]]; then
  echo "--release needs SIGN_IDENTITY and NOTARY_PROFILE in .signing.env (see the top of build.sh)" >&2
  exit 2
fi
# A Developer ID signature needs the hardened runtime and a secure timestamp.
SIGN=(--force --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && SIGN+=(--options runtime --timestamp)

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
rm "$BUILD"/Headroom-* "$BUILD"/HeadroomWidget-*

cp "$SRC/Support/App-Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Support/Widget-Info.plist" "$EXT/Contents/Info.plist"
cp "$SRC/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A personal badge for the widget's corner, if you keep one in Support/Local (not
# committed). Left out of release builds.
if (( ! RELEASE )) && [[ -f "$SRC/Support/Local/Badge.svg" ]]; then
  mkdir -p "$EXT/Contents/Resources"
  # With any extra poses: walking (the popover), sleeping (popover and widget).
  cp "$SRC"/Support/Local/Badge*.svg "$APP/Contents/Resources/"
  cp "$SRC"/Support/Local/Badge*.svg "$EXT/Contents/Resources/"
fi

# Sign inside out: the widget with its sandbox, then the app around it.
codesign "${SIGN[@]}" --entitlements "$SRC/Support/Widget.entitlements" "$EXT"
codesign "${SIGN[@]}" "$APP"
echo "built $APP"

if (( RELEASE )); then
  ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
  xcrun notarytool submit "$BUILD/notarize.zip" "${NOTARY[@]}" --wait
  rm "$BUILD/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute "$APP"
  ditto -c -k --keepParent --norsrc "$APP" "$BUILD/Headroom.zip"
  echo "notarized $BUILD/Headroom.zip"
fi

if (( INSTALL )); then
  osascript -e 'quit app "Headroom"' 2>/dev/null || true
  mkdir -p "${DEST:h}"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST"
  # Drop the build copy, or Spotlight lists Headroom twice.
  rm -rf "$APP"
  open "$DEST"
  echo "installed $DEST"
fi
