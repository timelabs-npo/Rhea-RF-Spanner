#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-all}"
mkdir -p build/logs
case "$mode" in
  core)
    swift --version | tee build/logs/swift-version.txt
    swift build -c release 2>&1 | tee build/logs/swift-build-release.log
    swift test 2>&1 | tee build/logs/swift-test.log
    ;;
  simulator|device|all)
    if ! command -v xcodebuild >/dev/null 2>&1; then
      echo "Xcode and the iOS SDK are required for the app build." >&2
      exit 69
    fi
    xcodebuild -version | tee build/logs/xcode-version.txt
    xcrun swift --version | tee build/logs/swift-version.txt
    if [ "$mode" = all ]; then
      "$0" core
    fi
    if [ "$mode" = simulator ] || [ "$mode" = all ]; then
      xcodebuild -project RheaRFSpanner.xcodeproj -scheme RheaRFSpanner \
        -configuration Debug -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/DerivedData-simulator \
        CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/logs/xcode-simulator.log
    fi
    if [ "$mode" = device ] || [ "$mode" = all ]; then
      xcodebuild -project RheaRFSpanner.xcodeproj -scheme RheaRFSpanner \
        -configuration Release -destination 'generic/platform=iOS' \
        -derivedDataPath build/DerivedData-device \
        CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/logs/xcode-device-unsigned.log
    fi
    ;;
  *) echo 'Usage: scripts/build.sh [core|simulator|device|all]' >&2; exit 64 ;;
esac

