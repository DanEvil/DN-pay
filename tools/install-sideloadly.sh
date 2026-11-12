#!/usr/bin/env bash
# Installs the unsigned MirWallet IPA on a connected iPhone using Sideloadly.
#
# Requirements (Windows):
#   * iTunes 64-bit from apple.com (NOT the Microsoft Store build)
#   * Sideloadly from https://sideloadly.io
#   * iPhone connected via USB, unlocked, "Trust this computer" confirmed
#
# On macOS / Linux use ./install-altstore.sh instead.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA="${1:-$HERE/../MirWallet.ipa}"
SIDELOADLY="${SIDELOADLY:-/c/Program Files/Sideloadly/Sideloadly.exe}"

if [ ! -f "$IPA" ]; then
  echo "IPA not found: $IPA" >&2
  echo "Build it first (GitHub Actions -> Build IPA -> download artifact) or pass a path." >&2
  exit 1
fi

if [ ! -f "$SIDELOADLY" ]; then
  echo "Sideloadly not found at: $SIDELOADLY" >&2
  echo "Download it from https://sideloadly.io and set SIDELOADLY=/path/to/Sideloadly.exe" >&2
  exit 1
fi

echo "Installing: $IPA"
echo "Sideloadly:  $SIDELOADLY"
echo
echo "Sideloadly is interactive: drag the IPA onto the window, choose your device,"
echo "enter your Apple ID, press Start. This script only verifies the inputs."
echo

# Sideloadly has no documented unattended CLI on Windows; verify what we can.
for required in "/c/Program Files/iTunes/iTunes.exe" "/c/Program Files (x86)/Apple/Mobile Device Support/AppleMobileDeviceService.exe"; do
  if [ ! -e "$required" ]; then
    echo "WARNING: expected Apple component missing: $required" >&2
    echo "         Install iTunes 64-bit from apple.com and enable Apple Mobile Device Support." >&2
  fi
done

exec "$SIDELOADLY" "$IPA"
