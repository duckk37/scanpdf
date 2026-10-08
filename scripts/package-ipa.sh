#!/usr/bin/env bash
# Produce an IPA for SideStore to sign with the user's own Apple Account.
# The '-' code signature is ad-hoc integrity signing, not Apple device provisioning.
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
  echo "Usage: bash scripts/package-ipa.sh path/to/ScanPDF.app output.ipa" >&2
  exit 1
fi
app_source="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output_dir="$(cd "$(dirname "$2")" && pwd)"
ipa_path="$output_dir/$(basename "$2")"
staging="$(mktemp -d "${TMPDIR:-/tmp}/scanpdf-ipa.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto "$app_source" "$staging/Payload/ScanPDF.app"
app="$staging/Payload/ScanPDF.app"
rm -rf "$app/_CodeSignature"
rm -f "$app/embedded.mobileprovision"

if [[ -d "$app/Frameworks" ]]; then
  while IFS= read -r -d '' binary; do
    codesign --force --sign - --timestamp=none "$binary"
  done < <(find "$app/Frameworks" -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' framework; do
    codesign --force --sign - --timestamp=none "$framework"
  done < <(find "$app/Frameworks" -depth -type d -name '*.framework' -print0)
fi
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")" = 'com.duckk37.scanpdf'
xcrun lipo -verify_arch arm64 "$app/ScanPDF"
ditto -c -k --norsrc --keepParent "$staging/Payload" "$ipa_path"
unzip -t "$ipa_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$ipa_path")" > "$(basename "$ipa_path").sha256")
echo "Created $ipa_path (SideStore must re-sign before installation)."
