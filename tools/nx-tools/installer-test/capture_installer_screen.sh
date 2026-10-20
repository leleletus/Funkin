#!/usr/bin/env bash
# Shows the installer screen of the current test build in Citron and saves a capture of the desktop, to check what
# the player sees. Uses an empty assets folder on Citron's SD card.
#
#   ./tools/nx-tools/installer-test/capture_installer_screen.sh <out.png> [offer|download] [seconds]
#
# offer:    the first screen (no download started)
# download: installer_autostart=true, captured while downloading
# Needs KDE's spectacle. Citron is closed afterwards.
set -u
OUT="${1:?output png}"
MODE="${2:-offer}"
WAIT="${3:-12}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SD="$HOME/.local/share/citron/sdmc/switch/Friday-Night-Funkin"
CFG="$SD/nx_devtools.cfg"

python3 "$ROOT/tools/nx-tools/sync_sd_assets.py" --clear > /dev/null
rm -f "$SD/logs/installer.log"
[ -f "$CFG" ] && sed -i '/installer_autostart/d' "$CFG"
[ "$MODE" = "download" ] && echo "installer_autostart=true" >> "$CFG"

(cd "$ROOT" && ./tools/nx-tools/run_citron_autotest.sh PUBLIC_SMOKE 300 > /dev/null 2>&1 &)
for _ in $(seq 1 120); do
  grep -q "quick check" "$SD/logs/installer.log" 2> /dev/null && break
  sleep 2
done
sleep "$WAIT"
spectacle -b -n -f -o "$OUT" 2> /dev/null
ps -eo pid,comm | awk '$2 ~ /citron/ {print $1}' | xargs -r kill -9
[ -f "$CFG" ] && sed -i '/installer_autostart/d' "$CFG"
echo "[capture_installer_screen] $OUT"
cat "$SD/logs/installer.log" 2> /dev/null | tail -3
