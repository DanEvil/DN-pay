#!/usr/bin/env bash
# Installs the unsigned MirWallet IPA on a connected iPhone using Sideloadly.
#
# This machine already has:
#   * iTunes 64-bit (C:/Program Files/iTunes/iTunes.exe)
#   * Apple Mobile Device Support + running "Apple Mobile Device Service"
#   * Sideloadly at C:/Users/nenas/AppData/Local/Sideloadly/sideloadly.exe
#
# Sideloadly is a GUI-only app (Go + Qt): it has no documented unattended CLI.
# It opens with the IPA preloaded; you pick the device and sign in.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA="${1:-$HERE/../MirWallet.ipa}"
SIDELOADLY="${SIDELOADLY:-/c/Users/nenas/AppData/Local/Sideloadly/sideloadly.exe}"

if [ ! -f "$IPA" ]; then
  echo "IPA not found: $IPA" >&2
  echo "Build it first (GitHub Actions -> Build IPA -> download artifact) or pass a path." >&2
  exit 1
fi

if [ ! -f "$SIDELOADLY" ]; then
  echo "Sideloadly not found at: $SIDELOADLY" >&2
  echo "Install it from https://sideloadly.io (Windows installer, installs to %LOCALAPPDATA%\\Sideloadly)." >&2
  exit 1
fi

echo "Installing: $IPA"
echo "Sideloadly:  $SIDELOADLY"
echo
echo "In the window: pick your device, enter your Apple ID, press Start."
echo "Free Apple ID -> the app expires after 7 days; paid Apple ID -> 1 year."
echo

# iTunes 64-bit from apple.com, not the Microsoft Store build.
if [ ! -e "/c/Program Files/iTunes/iTunes.exe" ]; then
  echo "WARNING: iTunes not found at 'C:/Program Files/iTunes/iTunes.exe'." >&2
  echo "         Sideloadly needs the 64-bit iTunes from apple.com (not the MS Store build)." >&2
fi

# Report whether an iPhone is currently visible over USB.
if [ -x "$LOCALAPPDATA/hermes/cache/scratch/pmd3env/Scripts/python.exe" ]; then
  "$LOCALAPPDATA/hermes/cache/scratch/pmd3env/Scripts/python.exe" -c "
import asyncio
try:
    from pymobiledevice3.usbmux import list_devices
except Exception:
    raise SystemExit(0)
async def main():
    try:
        devices = await list_devices()
    except Exception:
        devices = []
    print('Connected USB devices: %d' % len(devices))
    for d in devices:
        print('  ', d)
    if not devices:
        print('  -> Connect and unlock the iPhone over USB, then confirm Trust this computer.')
asyncio.run(main())
" || true
fi

exec "$SIDELOADLY" "$IPA"
