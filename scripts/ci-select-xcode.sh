#!/bin/bash
# CI only: makes the newest installed Xcode 26 (or later) the active one, since the macOS 26 SDK
# is required. Runner images keep several Xcodes side by side as /Applications/Xcode_<version>.app.
set -euo pipefail

major() { xcodebuild -version | awk 'NR == 1 { split($2, v, "."); print v[1] }'; }

if [ "$(major)" -lt 26 ]; then
  newest="$(ls -d /Applications/Xcode_2[6-9]*.app 2>/dev/null | sort -V | tail -1 || true)"
  if [ -z "$newest" ]; then
    echo "error: this runner has no Xcode 26 or later" >&2
    exit 1
  fi
  sudo xcode-select -s "$newest/Contents/Developer"
fi
xcodebuild -version
