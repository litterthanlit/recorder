#!/usr/bin/env bash
# Signs Recorder with your Apple Development certificate so macOS keeps its Screen
# Recording, Accessibility, Camera, and Microphone permissions across rebuilds.
#
# Usage:
#   scripts/configure-signing.sh             # use the team of your Apple Development certificate
#   scripts/configure-signing.sh ABCDE12345  # or pass a Team ID explicitly
#
# Writes Config/Local.xcconfig (git-ignored), keeping any other settings already in it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
local_config="$repo_root/Config/Local.xcconfig"
team_id="${1:-}"

if [[ -z "$team_id" ]]; then
  # The team ID is the organizational unit (OU) in the certificate's subject.
  team_id="$(
    security find-certificate -c "Apple Development" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | grep -oE 'OU ?= ?[A-Z0-9]{10}' \
      | head -n 1 \
      | grep -oE '[A-Z0-9]{10}$' \
      || true
  )"
fi

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Couldn't find an Apple Development certificate in your keychain." >&2
  echo "Sign in under Xcode > Settings > Accounts (Xcode creates one), or pass your Team ID:" >&2
  echo "  scripts/configure-signing.sh ABCDE12345" >&2
  exit 1
fi

# Replace any previous team settings, keep everything else (e.g. a custom bundle ID).
existing=""
if [[ -f "$local_config" ]]; then
  existing="$(grep -vE '^[[:space:]]*(DEVELOPMENT_TEAM|RECORDER_SIGNING)[[:space:]]*=' "$local_config" || true)"
else
  existing="// Personal signing settings, written by scripts/configure-signing.sh (git-ignored)."
fi
{
  printf '%s\n' "$existing"
  printf 'DEVELOPMENT_TEAM = %s\n' "$team_id"
  printf 'RECORDER_SIGNING = team\n'
} > "$local_config"

cat <<MESSAGE
Recorder will be signed with team $team_id (Config/Local.xcconfig).

One-time cleanup: the next build has a new, stable signature, so macOS asks for its
permissions one last time. Remove old "Recorder" rows under System Settings >
Privacy & Security > Screen Recording and Accessibility, build and run, and grant
them again. From then on they persist across rebuilds.

Stale entries can also be cleared from the command line:
  tccutil reset ScreenCapture com.recorder.app
  tccutil reset Accessibility com.recorder.app
MESSAGE
