#!/bin/bash
# Signs the release zip from `make release` and adds it to appcast.xml, Sparkle's update feed.
#   make release && make appcast
# Output in ./build/appcast: appcast.xml, starting from the published feed (Info.plist's SUFeedURL,
# the newest GitHub release's appcast.xml) so it lists every release. Each item links to the zip in
# its own release (releases/download/vX.Y.Z/), where the release workflow attaches it with the feed.
# Pre-releases stay out of the feed.
#
# The private EdDSA key stays out of the repo: by default Sparkle's tools read it from the login
# Keychain (account "notemd", made by `generate_keys --account notemd`). CI passes
# SPARKLE_KEY_FILE instead, a file holding the exported key (`generate_keys --account notemd -x <file>`).
# Release notes: put NoteMD-<version>.html or .md next to the zip in build/appcast and they're
# embedded in the feed.
set -euo pipefail
cd "$(dirname "$0")/.."

FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Resources/Info.plist)"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
OUT="build/appcast"
APP="build/release/NoteMD.app"

if [ ! -x "$TOOLS/generate_appcast" ]; then
  swift package resolve --disable-keychain
fi
if [ ! -d "$APP" ]; then
  echo "error: no $APP; run make release first" >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: $APP has no SUPublicEDKey, so it couldn't install updates; add Resources/SparklePublicKey.txt and rebuild" >&2
  exit 1
fi
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
if [[ "$VERSION" == *-* ]]; then
  echo "error: $VERSION is a pre-release; installed copies only update to releases" >&2
  exit 1
fi
ZIP="build/release/NoteMD-$VERSION.zip"
# https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml → …/releases/download/v<version>/
PREFIX="${DOWNLOAD_URL_PREFIX:-${FEED_URL%%/releases/*}/releases/download/v$VERSION/}"

mkdir -p "$OUT"
# Keep earlier releases in the feed: start from the published one unless there's a local copy.
if [ ! -f "$OUT/appcast.xml" ] && [ -z "${NEW_FEED:-}" ]; then
  # releases/latest/download/ redirects to the newest release's asset.
  code="$(curl -sSL -o "$OUT/appcast.xml" -w '%{http_code}' "$FEED_URL" || true)"
  case "$code" in
    200) echo "Starting from the published feed" ;;
    404) rm -f "$OUT/appcast.xml"; echo "No published feed yet: starting a new one" ;;
    *) rm -f "$OUT/appcast.xml"
       echo "error: couldn't fetch $FEED_URL (HTTP $code); set NEW_FEED=1 to start a new feed anyway" >&2
       exit 1 ;;
  esac
fi
cp "$ZIP" "$OUT/"

KEY_FLAGS=(--account notemd)
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then KEY_FLAGS=(--ed-key-file "$SPARKLE_KEY_FILE"); fi
"$TOOLS/generate_appcast" "${KEY_FLAGS[@]}" --download-url-prefix "$PREFIX" \
  --embed-release-notes --maximum-deltas 0 --maximum-versions 0 "$OUT"

# With a key that doesn't match the app's SUPublicEDKey, generate_appcast only warns and writes the
# item unsigned, which installed copies would refuse. Never let that feed be uploaded.
if ! grep -F "/$(basename "$ZIP")\"" "$OUT/appcast.xml" | grep -q 'sparkle:edSignature='; then
  echo "error: $(basename "$ZIP") isn't signed in $OUT/appcast.xml: the private key doesn't match the app's SUPublicEDKey" >&2
  exit 1
fi

echo "✓ $OUT/appcast.xml lists NoteMD $VERSION, linked to $PREFIX$(basename "$ZIP"); the v$VERSION release needs both"
