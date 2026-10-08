#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate --spec project.yml
mkdir -p build

simulator_id="$(python3 scripts/select-simulator.py)"
echo "Testing with iPhone simulator: $simulator_id"
if ! xcrun simctl boot "$simulator_id"; then
  # boot returns a nonzero status when the simulator is already booted.
  xcrun simctl list devices booted --json | python3 -c \
    'import json,sys; uid=sys.argv[1]; assert any(d["udid"] == uid for devices in json.load(sys.stdin)["devices"].values() for d in devices)' \
    "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b

result_path="build/Tests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$(date +%s)}.xcresult"
xcodebuild test \
  -project ScanPDF.xcodeproj \
  -scheme ScanPDF \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -destination-timeout 180 \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "$result_path" \
  CODE_SIGNING_ALLOWED=NO

# Confirm the app launches outside the XCTest host, and preserve the initial UI.
xcrun simctl install "$simulator_id" build/DerivedData/Build/Products/Debug-iphonesimulator/ScanPDF.app
launch_result="$(xcrun simctl launch --terminate-running-process "$simulator_id" com.duckk37.scanpdf)"
echo "$launch_result"
app_pid="${launch_result##*: }"
sleep 3
kill -0 "$app_pid"
xcrun simctl io "$simulator_id" screenshot build/ScanPDF-Simulator.png

xcodebuild build \
  -project ScanPDF.xcodeproj \
  -scheme ScanPDF \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

bash scripts/package-ipa.sh \
  build/DerivedData/Build/Products/Release-iphoneos/ScanPDF.app \
  build/ScanPDF-SideStore.ipa
