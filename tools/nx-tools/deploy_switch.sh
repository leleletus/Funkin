#!/usr/bin/env bash
# ==============================================================================
# Deploys a build to the Nintendo Switch and collects the hardware logs first.
#
#   ./tools/nx-tools/deploy_switch.sh [path/to/Funkin.nro]      # backup + wipe + upload
#   ./tools/nx-tools/deploy_switch.sh --logs-only                # only download logs/saves
#   ./tools/nx-tools/deploy_switch.sh --release [path/to/Funkin.nro]  # public build: no nx_devtools.cfg
#   ./tools/nx-tools/deploy_switch.sh --bench                    # backup + upload the video bench to
#                                                                  /switch/Funkin-videobench.nro (no wipe)
#
# Transport order: FTP (192.168.18.198:5000, e.g. sys-ftpd) -> MTP (DBI MTP Responder through KDE KIO).
# If neither is available it stops and asks to connect the console.
#
# Steps: 1) download logs/ and saves/ to ~/switch-backups/<date>_<label>
#        2) delete everything inside /switch/Friday-Night-Funkin (old saves/configs can break a new build)
#        3) upload the .nro and verify its size
#        4) upload tools/nx-tools/nx_devtools.cfg (test options such as botplay; skipped with --release)
# ==============================================================================
set -u

FTP_URL="${NX_FTP_URL:-ftp://192.168.18.198:5000}"
MTP_ROOT="${NX_MTP_ROOT:-mtp:/DBI MTP Responder/1: SD Card}"
GAME_DIR="/switch/Friday-Night-Funkin"
LOGS_ONLY=0
RELEASE=0
BENCH=0
case "${1:-}" in
    --logs-only) LOGS_ONLY=1; shift ;;
    --release) RELEASE=1; shift ;;
    --bench) BENCH=1; shift ;;
esac
BENCH_NRO="$(dirname "$0")/videobench/Funkin-videobench.nro"
NRO="${1:-$(dirname "$0")/../../export/release/switch/bin/Funkin.nro}"
DEVTOOLS_CFG="$(dirname "$0")/nx_devtools.cfg"
BACKUP="$HOME/switch-backups/Friday-Night-Funkin_$(date +%Y%m%d-%H%M%S)"

log() { echo "[deploy_switch] $*"; }

# ------------------------------------------------------------------ transports
ftp_available() { timeout 8 curl -s --list-only "$FTP_URL$GAME_DIR/" > /dev/null 2>&1; }
mtp_available() { command -v kioclient > /dev/null && timeout 20 kioclient ls "$MTP_ROOT$GAME_DIR/" > /dev/null 2>&1; }

ftp_ls() { timeout 20 curl -s --list-only "$FTP_URL$GAME_DIR/$1/" 2>/dev/null | xargs -r -n1 basename; }
mtp_ls() { timeout 30 kioclient ls "$MTP_ROOT$GAME_DIR/$1/" 2>/dev/null | grep -v -E '^\.?$'; }

ftp_get() { timeout 300 curl -s -o "$2" "$FTP_URL$GAME_DIR/$1"; }
mtp_get() { timeout 300 kioclient cat "$MTP_ROOT$GAME_DIR/$1" > "$2"; }

ftp_rm() { timeout 30 curl -s "$FTP_URL/" -Q "DELE $GAME_DIR/$1" -o /dev/null; }
ftp_rmdir() { timeout 30 curl -s "$FTP_URL/" -Q "RMD $GAME_DIR/$1" -o /dev/null; }
mtp_rm() { timeout 60 kioclient --noninteractive remove "$MTP_ROOT$GAME_DIR/$1" > /dev/null 2>&1; }

ftp_put() { curl -s -S -T "$1" "$FTP_URL$GAME_DIR/${2:-Funkin.nro}"; }
mtp_put() { kioclient --noninteractive --overwrite copy "$1" "$MTP_ROOT$GAME_DIR/${2:-Funkin.nro}"; }

ftp_size() { curl -s -I "$FTP_URL$GAME_DIR/Funkin.nro" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r'; }
# kioclient stat reads the size from the device without transferring the file again.
mtp_size() { timeout 30 kioclient stat "$MTP_ROOT$GAME_DIR/Funkin.nro" 2>/dev/null | awk '$1=="SIZE"{print $2}'; }

if ftp_available; then T=ftp; elif mtp_available; then T=mtp; else
    log "No FTP ($FTP_URL) and no MTP ($MTP_ROOT) access to the console."
    log "Turn on the FTP server or connect the Switch with DBI MTP Responder, then run this again."
    exit 2
fi
log "Using $T"

# ------------------------------------------------------------------ 1. backup
mkdir -p "$BACKUP"
for dir in logs saves saves/FunkinCrew; do
    for f in $(${T}_ls "$dir"); do
        case "$f" in FunkinCrew) continue ;; esac
        mkdir -p "$BACKUP/$dir"
        ${T}_get "$dir/$f" "$BACKUP/$dir/$f" && log "backup $dir/$f ($(stat -c %s "$BACKUP/$dir/$f") bytes)"
    done
done
log "Backup: $BACKUP"
[ "$LOGS_ONLY" = "1" ] && exit 0

# ------------------------------------------------------------------ video bench (VIDEO_BENCH)
# It goes straight in /switch: the homebrew menu shows a single .nro per folder. It writes logs/videobench.log.
if [ "$BENCH" = "1" ]; then
    if [ ! -f "$BENCH_NRO" ]; then log "Bench NRO not found: $BENCH_NRO (make -C tools/nx-tools/videobench)"; exit 1; fi
    log "Uploading the video bench ($(stat -c %s "$BENCH_NRO") bytes) to /switch/Funkin-videobench.nro..."
    if [ "$T" = "ftp" ]; then
        curl -s -S -T "$BENCH_NRO" "$FTP_URL/switch/Funkin-videobench.nro" || { log "Upload failed"; exit 1; }
    else
        kioclient --noninteractive --overwrite copy "$BENCH_NRO" "$MTP_ROOT/switch/Funkin-videobench.nro" || { log "Upload failed"; exit 1; }
    fi
    log "Done. Run 'Funkin-videobench' from the homebrew menu (about 10 min), then: deploy_switch.sh --logs-only"
    exit 0
fi

# ------------------------------------------------------------------ 2. wipe
if [ ! -f "$NRO" ]; then log "NRO not found: $NRO"; exit 1; fi
if [ "$T" = "ftp" ]; then
    for dir in logs saves/FunkinCrew; do for f in $(ftp_ls "$dir"); do ftp_rm "$dir/$f"; done; done
    ftp_rm "Funkin.nro"; ftp_rm "nx_devtools.cfg"; ftp_rm "autotest.cfg"
    for dir in saves/FunkinCrew saves logs mods; do ftp_rmdir "$dir"; done
else
    for entry in logs saves mods Funkin.nro nx_devtools.cfg autotest.cfg; do mtp_rm "$entry"; done
fi
log "Remaining after wipe: $(${T}_ls . | tr '\n' ' ')"

# ------------------------------------------------------------------ 3. upload
log "Uploading $(basename "$NRO") ($(stat -c %s "$NRO") bytes)..."
${T}_put "$NRO" || { log "Upload failed"; exit 1; }
REMOTE=$(${T}_size)
LOCAL=$(stat -c %s "$NRO")
if [ "$REMOTE" = "$LOCAL" ]; then log "Upload verified ($LOCAL bytes)."; else log "SIZE MISMATCH: remote=$REMOTE local=$LOCAL"; exit 1; fi

# ------------------------------------------------------------------ 4. test options
if [ "$RELEASE" = "1" ]; then
    log "Release deploy: nx_devtools.cfg not copied."
elif [ -f "$DEVTOOLS_CFG" ]; then
    ${T}_put "$DEVTOOLS_CFG" nx_devtools.cfg > /dev/null && log "nx_devtools.cfg copied: $(grep -E '^[a-z_]+=' "$DEVTOOLS_CFG" | tr '\n' ' ')"
fi
