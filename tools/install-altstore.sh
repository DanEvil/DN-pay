#!/usr/bin/env bash
# Installs the unsigned MirWallet IPA on a connected iPhone using AltStore / AltServer.
#
# Requirements (Windows):
#   * iTunes 64-bit from apple.com (NOT the Microsoft Store build)
#   * AltServer for Windows from https://altstore.io
#   * iPhone connected via USB, unlocked, "Trust this computer" confirmed
#   * Developer Mode enabled on the device (Settings -> Privacy & Security -> Developer Mode)
#
# AltServer can install a plain .ipa directly (hold Shift while clicking the
# tray icon -> "Sideload .ipa..."), which is what this script automates when
# the AltServer binary is on PATH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA="${1:-$HERE/../MirWallet.ipa}"
ALTSERVER="${ALTSERVER:-/c/Program Files (x86)/AltStore/AltServer.exe}"

if [ ! -f "$IPA" ]; then
  echo "IPA not found: $IPA" >&2
  echo "Build it first (GitHub Actions -> Build IPA -> download artifact) or pass a path." >&2
  exit 1
fi

if [ ! -f "$ALTSERVER" ]; then
  echo "AltServer not found at: $ALTSERVER" >&2
  echo "Download AltServer from https://altstore.io and set ALTSERVER=/path/to/AltServer.exe" >&2
  exit 1
fi

echo "Installing: $IPA"
echo "AltServer:   $ALTSERVER"
echo

# AltServer on Windows exposes the sideload action through the tray menu.
# The documented unattended switch is available in recent builds; fall back to
# the GUI instructions otherwise.
if "$ALTSERVER" --sideload "$IPA" 2>/dev/null; then
  echo "AltServer reported success."
  exit 0
fi

cat <<'EOF'
AltServer did not accept the unattended switch on this machine. Install manually:

  1. Connect and unlock the iPhone over USB.
  2. Start AltServer (tray icon).
  3. Hold Shift while clicking the tray icon -> "Sideload .ipa...".
  4. Choose the .ipa, pick the device, enter your Apple ID, press Start.

AltStore Classic requires iOS 17.4+ on the device.
EOF
