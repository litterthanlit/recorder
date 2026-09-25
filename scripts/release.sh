#!/usr/bin/env bash
# Builds Recorder for distribution outside the App Store: Release configuration, signed
# with your Developer ID Application certificate (hardened runtime, secure timestamp),
# notarized by Apple, and stapled, so it opens on other Macs without Gatekeeper warnings.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode > Settings > Accounts >
#      Manage Certificates, or developer.apple.com) so it's in your login keychain.
#   2. Store notarization credentials in the keychain under a profile name:
#        xcrun notarytool store-credentials recorder-notary \
#          --apple-id you@example.com --team-id ABCDE12345
#      (it asks for an app-specific password from appleid.apple.com).
#
# Usage:
#   scripts/release.sh [TEAM_ID]
#
# TEAM_ID defaults to DEVELOPMENT_TEAM in Config/Local.xcconfig. The notary profile
# defaults to "recorder-notary"; set NOTARY_PROFILE to use another. Set SKIP_NOTARIZE=1
# to only build and sign. Output: build/release/Recorder.zip (notarized and stapled).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

team_id="${1:-}"
if [[ -z "$team_id" && -f Config/Local.xcconfig ]]; then
  team_id="$(sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*([A-Z0-9]{10}).*/\1/p' Config/Local.xcconfig | head -n 1)"
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Pass your Team ID (scripts/release.sh ABCDE12345) or run scripts/configure-signing.sh first." >&2
  exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "No \"Developer ID Application\" certificate in your keychain; see the setup notes in $0." >&2
  exit 1
fi

notary_profile="${NOTARY_PROFILE:-recorder-notary}"
out_dir="$repo_root/build/release"
app="$out_dir/build/Release/Recorder.app"
zip="$out_dir/Recorder.zip"

rm -rf "$out_dir"
mkdir -p "$out_dir"

echo "==> Building Release, signed with Developer ID (team $team_id)"
xcodebuild \
  -project Recorder.xcodeproj \
  -target Recorder \
  -configuration Release \
  -quiet \
  SYMROOT="$out_dir/build" \
  RECORDER_SIGNING=developerid \
  DEVELOPMENT_TEAM="$team_id" \
  build

echo "==> Checking the signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --verbose=2 "$app" 2>&1 | grep -E '^(Authority=Developer ID Application|Timestamp=|flags=.*runtime)' \
  || { echo "Not signed with Developer ID, a timestamp and the hardened runtime." >&2; exit 1; }

# notarytool takes a zip; ditto keeps the bundle's symlinks and extended attributes.
ditto -c -k --keepParent "$app" "$zip"

if [[ "${SKIP_NOTARIZE:-0}" == 1 ]]; then
  echo "Signed (not notarized): $zip"
  exit 0
fi

echo "==> Notarizing (usually a few minutes)"
if ! xcrun notarytool submit "$zip" --keychain-profile "$notary_profile" --wait; then
  echo "Notarization failed. For details: xcrun notarytool log <submission id> --keychain-profile $notary_profile" >&2
  exit 1
fi

echo "==> Stapling the ticket"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

# Re-zip so the download carries the stapled ticket (works offline).
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "Done: $zip"
