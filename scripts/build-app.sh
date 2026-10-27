#!/usr/bin/env bash
# Assembles NoteMD.app from the SwiftPM build.
# Usage: scripts/build-app.sh [release|dev|test]
#   SIGN_IDENTITY="Developer ID Application: …"   # sign with a real identity: hardened runtime + secure timestamp
#                                                 # (default: ad-hoc; scripts/release.sh sets it)
#   ARCH=arm64                                    # build for one architecture (default: this Mac's)
#   VERSION=1.2.3 BUILD=456                       # override ./VERSION and the commit-count build number
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

# The version lives in ./VERSION; the build number counts commits, so it only ever grows (Sparkle compares it).
# CI builds from a full clone.
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# The Share menu extension registers system-wide: only the release build embeds it, unless SHARE=1.
if [[ -z "${SHARE:-}" ]]; then SHARE=$([[ "$VARIANT" == "release" ]] && echo 1 || echo 0); fi

SWIFT_FLAGS=(-c "$CONFIG" --disable-keychain)  # never a Keychain prompt when packages download
if [[ -n "${ARCH:-}" ]]; then SWIFT_FLAGS+=(--arch "$ARCH"); fi
swift build "${SWIFT_FLAGS[@]}" --product NoteMD
if [[ "$SHARE" == "1" ]]; then swift build "${SWIFT_FLAGS[@]}" --product NoteMDShare; fi
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
APP="build/$NAME.app"
PLIST="$APP/Contents/Info.plist"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/NoteMD" "$APP/Contents/MacOS/NoteMD"
# SwiftPM also adds this checkout's build folder as an rpath; the bundle only needs @-relative ones.
otool -l "$APP/Contents/MacOS/NoteMD" | awk '/LC_RPATH/ { getline; getline; print $2 }' | { grep '^/' || true; } |
  while read -r path; do install_name_tool -delete_rpath "$path" "$APP/Contents/MacOS/NoteMD" 2>/dev/null; done
# Sparkle (updates, decision-10). Every variant links it; ditto keeps the framework's symlinks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# Sparkle ships universal; a one-architecture build keeps only that slice (signed again below).
if [[ -n "${ARCH:-}" ]]; then
  find "$APP/Contents/Frameworks/Sparkle.framework" -type f -perm -u+x | while read -r binary; do
    archs="$(lipo -archs "$binary" 2>/dev/null || true)"
    if [[ " $archs " == *" $ARCH "* && "$archs" != "$ARCH" ]]; then lipo -thin "$ARCH" "$binary" -output "$binary"; fi
  done
fi
cp Resources/Info.plist "$PLIST"
cp Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
# Third-party license notices, shown by the standard About panel; fails if a package has no license file.
swift scripts/acknowledgements.swift Package.resolved .build/checkouts "$APP/Contents/Resources/Credits.html"

pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleIdentifier $BUNDLE_ID"
pb "Set :CFBundleName $NAME"
pb "Set :CFBundleDisplayName $NAME"
pb "Set :CFBundleShortVersionString $VERSION"
pb "Set :CFBundleVersion $BUILD"
pb "Set :AppVariant $VARIANT"
pb "Set :AppURLScheme $SCHEME"
pb "Set :CFBundleURLTypes:0:CFBundleURLName $BUNDLE_ID"
pb "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $SCHEME"
pb "Set :NSServices:0:NSMenuItem:default New $NAME Note"
pb "Set :NSServices:0:NSPortName $NAME"
# Updates: the feed URL is in Info.plist; the public EdDSA key comes from Resources/SparklePublicKey.txt. Dev and
# Test builds have no updater, so they never replace themselves with the release.
if [[ "$VARIANT" == "release" ]]; then
  # No key file yet is a warning, not a failure (set -e would stop at a failed read).
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$({ tr -d '[:space:]' < Resources/SparklePublicKey.txt; } 2>/dev/null || true)}"
  if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    pb "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY"
  else
    echo "⚠ No Resources/SparklePublicKey.txt: this build can't update itself (docs/releasing.md)" >&2
  fi
else
  pb "Delete :SUFeedURL"
  pb "Delete :SUEnableAutomaticChecks"
fi
if [[ "$VARIANT" == "test" ]]; then
  # Background agent build: no Dock icon, never steals focus, no App Nap.
  pb "Add :LSUIElement bool true"
  pb "Add :NSAppSleepDisabled bool true"
  pb "Add :AppBackground bool true"
fi

# App icon (Icon Composer .icon -> Assets.car + AppIcon.icns).
if [[ -d Resources/AppIcon.icon ]]; then
  ICON_DIR="$(mktemp -d)"
  # Absolute paths: actool can resolve relative ones against another project's directory. It can exit 0 on failure,
  # so the compiled catalog is checked too.
  if ! xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon \
      --platform macosx --target-device mac --minimum-deployment-target 26.0 \
      --output-partial-info-plist "$ICON_DIR/icon.plist" --errors --warnings >"$ICON_DIR/actool.log" ||
    [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    cat "$ICON_DIR/actool.log" >&2
    echo "✗ actool couldn't compile Resources/AppIcon.icon" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Merge $ICON_DIR/icon.plist" "$PLIST"
  rm -rf "$ICON_DIR"
fi

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
# Notarization wants the hardened runtime and a secure timestamp, which ad-hoc signatures can't have.
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
# codesign without its "replacing existing signature" note (Sparkle's parts come pre-signed).
sign() { codesign "$@" 2> >(grep -v ': replacing existing signature$' >&2); }

# Nested code is signed before the bundle that contains it, innermost first (Sparkle's order; the Downloader
# service keeps its own entitlements).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "${SIGN_FLAGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
sign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "${SIGN_FLAGS[@]}" "$SPARKLE/Autoupdate"
sign "${SIGN_FLAGS[@]}" "$SPARKLE/Updater.app"
sign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"

# Share menu extension (sandboxed), signed before the app that seals it.
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
  sign "${SIGN_FLAGS[@]}" --entitlements Resources/Share/NoteMDShare.entitlements "$APPEX"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  sign "${SIGN_FLAGS[@]}" "$APP"
else
  sign "${SIGN_FLAGS[@]}" --entitlements Resources/NoteMD.entitlements "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
