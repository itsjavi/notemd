#!/usr/bin/env bash
# Assembles NoteMD.app from the SwiftPM build.
# Usage: scripts/build-app.sh [release|dev|test]
#   SIGN_IDENTITY="Developer ID Application: …"   # sign with a real identity: hardened runtime + secure timestamp
#                                                 # (default: ad-hoc; scripts/release.sh sets it)
#   SHARE=1                                       # embed the Share menu extension in a Dev/Test build too
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-release}"
case "$VARIANT" in
  release) CONFIG=release; NAME="NoteMD";      BUNDLE_ID="com.itsjavi.notemd";      SCHEME="notemd" ;;
  dev)     CONFIG=debug;   NAME="NoteMD Dev";  BUNDLE_ID="com.itsjavi.notemd.dev";  SCHEME="notemd-dev" ;;
  test)    CONFIG=debug;   NAME="NoteMD Test"; BUNDLE_ID="com.itsjavi.notemd.test"; SCHEME="notemd-test" ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 64 ;;
esac

# The Share menu extension registers system-wide: only the release build embeds it, unless SHARE=1.
if [[ -z "${SHARE:-}" ]]; then SHARE=$([[ "$VARIANT" == "release" ]] && echo 1 || echo 0); fi

swift build -c "$CONFIG" --product NoteMD
if [[ "$SHARE" == "1" ]]; then swift build -c "$CONFIG" --product NoteMDShare; fi
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/$NAME.app"
PLIST="$APP/Contents/Info.plist"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NoteMD" "$APP/Contents/MacOS/NoteMD"
cp Resources/Info.plist "$PLIST"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"

pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleIdentifier $BUNDLE_ID"
pb "Set :CFBundleName $NAME"
pb "Set :CFBundleDisplayName $NAME"
pb "Set :AppVariant $VARIANT"
pb "Set :AppURLScheme $SCHEME"
pb "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID"
pb "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $SCHEME"
pb "Set :NSServices:0:NSMenuItem:default New $NAME Note"
pb "Set :NSServices:0:NSPortName $NAME"
if [[ -n "${BUILD_NUMBER:-}" ]]; then pb "Set :CFBundleVersion $BUILD_NUMBER"; fi
if [[ "$VARIANT" == "test" ]]; then
  # Background agent build: no Dock icon, never steals focus, no App Nap.
  pb "Add :LSUIElement bool true"
  pb "Add :NSAppSleepDisabled bool true"
  pb "Add :AppBackground bool true"
fi

# App icon (Icon Composer .icon -> Assets.car + AppIcon.icns).
if [[ -d Resources/AppIcon.icon ]]; then
  ICON_DIR="$(mktemp -d)"
  # Absolute paths: actool can resolve relative ones against another project's directory.
  xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target 26.0 \
    --output-partial-info-plist "$ICON_DIR/icon.plist" --errors --warnings >/dev/null
  /usr/libexec/PlistBuddy -c "Merge $ICON_DIR/icon.plist" "$PLIST"
  rm -rf "$ICON_DIR"
fi

# Share menu extension (sandboxed), signed before the app that seals it.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SHARE" == "1" ]]; then
  APPEX="$APP/Contents/PlugIns/NoteMDShare.appex"
  APPEX_PLIST="$APPEX/Contents/Info.plist"
  mkdir -p "$APPEX/Contents/MacOS"
  cp "$BIN/NoteMDShare" "$APPEX/Contents/MacOS/NoteMDShare"
  cp Resources/Share/Info.plist "$APPEX_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.share" "$APPEX_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME" "$APPEX_PLIST"
  /usr/libexec/PlistBuddy -c "Set :AppURLScheme $SCHEME" "$APPEX_PLIST"
  for key in CFBundleShortVersionString CFBundleVersion; do
    /usr/libexec/PlistBuddy -c "Set :$key $(pb "Print :$key")" "$APPEX_PLIST"
  done
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements Resources/Share/NoteMDShare.entitlements "$APPEX"
  else
    codesign --force --options runtime --timestamp --entitlements Resources/Share/NoteMDShare.entitlements --sign "$SIGN_IDENTITY" "$APPEX"
  fi
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --entitlements Resources/NoteMD.entitlements --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP"
