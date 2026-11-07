#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
options="${1:-}"
if [ -z "$options" ] || [ ! -f "$options" ]; then
  echo 'Usage: scripts/export.sh /absolute/path/to/ExportOptions.plist' >&2
  echo 'Use export options produced for the authorized Apple team; do not invent team identifiers.' >&2
  exit 64
fi
test -d build/RheaRFSpanner.xcarchive
xcodebuild -exportArchive -archivePath build/RheaRFSpanner.xcarchive \
  -exportOptionsPlist "$options" -exportPath build/export \
  2>&1 | tee build/logs/xcode-export.log

