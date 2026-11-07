#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'An authorized Mac with Xcode is required.' >&2
  exit 69
fi
if [ ! -f Config/Signing.local.xcconfig ]; then
  echo 'Signing configuration is missing: Config/Signing.local.xcconfig.' >&2
  exit 78
fi
if grep -q 'REPLACE_WITH_' Config/Signing.local.xcconfig; then
  echo 'Signing configuration still contains placeholders.' >&2
  exit 78
fi
major="$(xcodebuild -version | awk '/^Xcode / {split($2,a,"."); print a[1]; exit}')"
if [ -z "$major" ] || [ "$major" -lt 26 ]; then
  echo 'App Store Connect uploads require Xcode 26 or later as of 2026-11-07.' >&2
  exit 69
fi
mkdir -p build/logs
xcodebuild -project RheaRFSpanner.xcodeproj -scheme RheaRFSpanner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/RheaRFSpanner.xcarchive \
  archive 2>&1 | tee build/logs/xcode-archive.log
echo 'Signed archive created. Review it in Xcode Organizer before distribution.'

