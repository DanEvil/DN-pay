#!/usr/bin/env bash
# Installs the unsigned MirWallet IPA on a connected iPhone using AltStore / AltServer.
#
# AltServer lives next to this script and was extracted from the official
# AltStore installer (altinstaller.zip -> AltInstaller.msi -> AltServer.exe
# version 1.8.4.0). Apple Mobile Device Support is already installed on this
# machine, so no extra setup is needed.
#
# AltServer is a tray application. Hold Shift while clicking its tray icon
# and pick "Sideload .ipa...".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA="${1:-$HERE/../MirWallet.ipa}"
ALTSERVER="${ALTSERVER:-$HERE/../tools/AltServer/AltServer.exe}"

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

echo "Starting AltServer (look for the diamond icon in the system tray)."
echo "Then hold Shift and click the tray icon -> 'Sideload .ipa...' -> pick $IPA"
echo

"$ALTSERVER" &
sleep 3

cat <<'EOF'
AltStore Classic requires iOS 17.4+ on the device.
For an AltStore-typed install, AltServer must stay running and the iPhone
must be on the same Wi-Fi, or connected by USB.
EOF
