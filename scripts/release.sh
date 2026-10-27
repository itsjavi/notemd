#!/bin/bash
# Builds a release of NoteMD.app for Apple silicon into ./build/release: the app, a zip (for Sparkle updates)
# and a DMG (for downloads).
#
# Credentials, all optional (without them the build is ad-hoc signed, and other Macs need
# System Settings ▸ Privacy & Security ▸ Open Anyway on first launch):
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   # signing identity in the Keychain
#   NOTARY_PROFILE=<name>        # a notarytool Keychain profile, made once with
#                                # xcrun notarytool store-credentials <name> --apple-id … --team-id …
#   NOTARY_KEYCHAIN=<path>       # the keychain holding that profile, if not the login keychain (CI)
# VERSION and BUILD override ./VERSION and the commit-count build number (see build-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/release"
APP="build/NoteMD.app"
missing=()
if [ -z "${DEVELOPER_ID:-}" ]; then
  missing+=("DEVELOPER_ID (a Developer ID Application identity)")
elif ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "error: no signing identity matching \"$DEVELOPER_ID\" in the Keychain" >&2
  exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then missing+=("NOTARY_PROFILE (a notarytool Keychain profile)"); fi
if [ ! -s Resources/SparklePublicKey.txt ] && [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then missing+=("Resources/SparklePublicKey.txt (Sparkle's public key: without it the app can't update itself)"); fi

ARCH=arm64 SIGN_IDENTITY="${DEVELOPER_ID:--}" ./scripts/build-app.sh release
# Fails fast on a signing-order mistake instead of after a notarization round trip.
codesign --verify --deep --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
BASE="NoteMD-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"

make_zip() { ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$BASE.zip"; }

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
    ${NOTARY_KEYCHAIN:+--keychain "$NOTARY_KEYCHAIN"} --wait
}

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  # The app is notarized through a zip, then stapled so it opens offline too.
  make_zip
  notarize "$OUT/$BASE.zip"
  xcrun stapler staple "$APP"
  rm "$OUT/$BASE.zip"
fi
make_zip

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "NoteMD $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT/$BASE.dmg"
if [ -n "${DEVELOPER_ID:-}" ]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$OUT/$BASE.dmg"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize "$OUT/$BASE.dmg"
    xcrun stapler staple "$OUT/$BASE.dmg"
  fi
fi
cp -R "$APP" "$OUT/"
(cd "$OUT" && shasum -a 256 "$BASE.zip" "$BASE.dmg" > SHA256SUMS)

echo "✓ NoteMD $VERSION ($BUILD) in $OUT: NoteMD.app, $BASE.zip, $BASE.dmg, SHA256SUMS"
if [ ${#missing[@]} -gt 0 ]; then
  echo "⚠ Not ready to ship (ad-hoc builds need Open Anyway on other Macs on first launch). Missing:"
  for item in "${missing[@]}"; do echo "  - $item"; done
fi
