#!/usr/bin/env bash
# Optional real Apple signing. The provisioning profile must match the certificate,
# bundle identifier, and registered installation devices. Secrets stay in temp files.
set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
  echo "Usage: bash scripts/sign-ipa.sh path/to/ScanPDF.app output.ipa" >&2
  exit 1
fi
for secret_name in BUILD_CERTIFICATE_BASE64 P12_PASSWORD BUILD_PROVISION_PROFILE_BASE64 KEYCHAIN_PASSWORD; do
  if [[ -z "${!secret_name:-}" ]]; then
    echo "Missing signing secret: $secret_name" >&2
    exit 1
  fi
done
app_source="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$(dirname "$2")"
output_dir="$(cd "$(dirname "$2")" && pwd)"
ipa_path="$output_dir/$(basename "$2")"
signing_dir="$(mktemp -d "${TMPDIR:-/tmp}/scanpdf-sign.XXXXXX")"
keychain_path="$signing_dir/signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export SCANPDF_SIGNING_DIR="$signing_dir"
python3 - <<'PY'
import base64
import os
from pathlib import Path
root = Path(os.environ["SCANPDF_SIGNING_DIR"])
for variable, filename in (("BUILD_CERTIFICATE_BASE64", "certificate.p12"),
                           ("BUILD_PROVISION_PROFILE_BASE64", "profile.mobileprovision")):
    value = "".join(os.environ[variable].split())
    target = root / filename
    target.write_bytes(base64.b64decode(value, validate=True))
    target.chmod(0o600)
PY

security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
security import "$signing_dir/certificate.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 \
  -k "$keychain_path" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$keychain_path" >/dev/null
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"
security find-identity -v -p codesigning "$keychain_path" > "$signing_dir/identities.txt"
python3 - <<'PY'
import datetime
import hashlib
import os
import plistlib
import re
from pathlib import Path
root = Path(os.environ["SCANPDF_SIGNING_DIR"])
profile = plistlib.loads((root / "profile.plist").read_bytes())
expiration = profile.get("ExpirationDate")
if expiration is None or expiration <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
    raise SystemExit("The provisioning profile is expired or has no expiration date.")
if not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"):
    raise SystemExit("Use a development or Ad Hoc profile for device installation, not an App Store profile.")
bundle_id = "com.duckk37.scanpdf"
entitlements = profile["Entitlements"].copy()
allowed_id = entitlements.get("application-identifier", "")
prefix, separator, allowed_bundle = allowed_id.partition(".")
if not separator or not (allowed_bundle == bundle_id or
                         (allowed_bundle.endswith("*") and bundle_id.startswith(allowed_bundle[:-1]))):
    raise SystemExit("The provisioning profile does not authorize com.duckk37.scanpdf.")
entitlements["application-identifier"] = prefix + "." + bundle_id
# The app has no keychain capability. Omit the optional profile groups rather
# than passing a wildcard entitlement to codesign or inventing a group name.
entitlements.pop("keychain-access-groups", None)
with (root / "entitlements.plist").open("wb") as output:
    plistlib.dump(entitlements, output)
authorized = {hashlib.sha1(certificate).hexdigest().upper() for certificate in profile["DeveloperCertificates"]}
available = re.findall(r'^\s*\d+\)\s+([A-Fa-f0-9]{40})\s+"', (root / "identities.txt").read_text(), re.MULTILINE)
matches = [identity for identity in available if identity.upper() in authorized]
if not matches:
    raise SystemExit("The imported certificate/private key does not match this provisioning profile.")
(root / "identity.txt").write_text(matches[0])
PY
identity="$(cat "$signing_dir/identity.txt")"
mkdir -p "$signing_dir/Payload"
ditto "$app_source" "$signing_dir/Payload/ScanPDF.app"
app="$signing_dir/Payload/ScanPDF.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Info.plist")" = 'com.duckk37.scanpdf'
rm -rf "$app/_CodeSignature"
cp "$signing_dir/profile.mobileprovision" "$app/embedded.mobileprovision"
if [[ -d "$app/Frameworks" ]]; then
  while IFS= read -r -d '' binary; do
    codesign --force --sign "$identity" --keychain "$keychain_path" --timestamp=none "$binary"
  done < <(find "$app/Frameworks" -type f -name '*.dylib' -print0)
  while IFS= read -r -d '' framework; do
    codesign --force --sign "$identity" --keychain "$keychain_path" --timestamp=none "$framework"
  done < <(find "$app/Frameworks" -depth -type d -name '*.framework' -print0)
fi
codesign --force --sign "$identity" --keychain "$keychain_path" --timestamp=none \
  --entitlements "$signing_dir/entitlements.plist" --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$signing_dir/Payload" "$ipa_path"
unzip -t "$ipa_path"
(cd "$output_dir" && shasum -a 256 "$(basename "$ipa_path")" > "$(basename "$ipa_path").sha256")
echo "Created Apple-signed IPA. Installation is limited by the supplied provisioning profile."
