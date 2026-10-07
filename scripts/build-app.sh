#!/usr/bin/env bash
# Assembles NoteMD.app from the SwiftPM build.
# Usage: scripts/build-app.sh [release|dev|test]
set -euo pipefail
cd "$(dirname "$0")/.."

VARIANT="${1:-release}"
case "$VARIANT" in
  release) CONFIG=release; NAME="NoteMD";      BUNDLE_ID="com.itsjavi.notemd";      SCHEME="notemd" ;;
  dev)     CONFIG=debug;   NAME="NoteMD Dev";  BUNDLE_ID="com.itsjavi.notemd.dev";  SCHEME="notemd-dev" ;;
  test)    CONFIG=debug;   NAME="NoteMD Test"; BUNDLE_ID="com.itsjavi.notemd.test"; SCHEME="notemd-test" ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 64 ;;
esac

swift build -c "$CONFIG" --product NoteMD
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

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "Built $APP"
