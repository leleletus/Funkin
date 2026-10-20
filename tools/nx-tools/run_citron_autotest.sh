#!/usr/bin/env bash
# ==============================================================================
# Autonomous Citron Test Runner for Friday Night Funkin' (Nintendo Switch Port)
# ==============================================================================
set -e

SCENARIO="${1:-CUTSCENE_DARNELL}"
TIMEOUT_SEC="${2:-150}"
# PUBLIC_SMOKE: for public builds (no -DNX_DEV_TOOLS, so no autotests and no log). No autotest.cfg is written;
# it passes if Citron is still running after TIMEOUT_SEC with no native crash and nothing was written under logs/.
# CITRON_STDOUT=<file> keeps Citron's own stdout/stderr (e.g. its SIGSEGV backtrace); default /dev/null.
# Always launch Citron through this script: it sets APPIMAGELAUNCHER_DISABLE=1 and kills the whole process tree.
SMOKE=0
[ "$SCENARIO" = "PUBLIC_SMOKE" ] && SMOKE=1
# VIDEO_BENCH: runs the Citron build of the standalone decoder bench (tools/nx-tools/videobench, see main.c) instead of
# the game; it passes when logs/videobench.log says "done" with no decoding error. Citron's timings are not valid.
BENCH=0
[ "$SCENARIO" = "VIDEO_BENCH" ] && BENCH=1

CITRON_BIN="/home/djvemo/Applications/citron_nightly-308bc267c-linux-x86_64-use-nopgo_f1ac8aeaee5c67403a7d350daea956eb.AppImage"
NRO_PATH="/home/djvemo/Funkin/export/release/switch/bin/Funkin.nro"
SDMC_DIR="/home/djvemo/.local/share/citron/sdmc/switch/Friday-Night-Funkin"
CFG_FILE="$SDMC_DIR/autotest.cfg"
LOG_FILE="$SDMC_DIR/logs/deep_engine_trace.log"
if [ "$BENCH" = "1" ]; then
    NRO_PATH="/home/djvemo/Funkin/tools/nx-tools/videobench/Funkin-videobench-citron.nro"
    LOG_FILE="$SDMC_DIR/logs/videobench.log"
fi

export APPIMAGELAUNCHER_DISABLE=1

if [ ! -f "$CITRON_BIN" ]; then
    echo "[AUTOTEST-RUNNER] ERROR: Citron binary not found at $CITRON_BIN"
    exit 1
fi

if [ ! -f "$NRO_PATH" ]; then
    echo "[AUTOTEST-RUNNER] ERROR: Game binary not found at $NRO_PATH"
    exit 1
fi

mkdir -p "$SDMC_DIR/logs"

# 1. Limpiar marcas de AUTOTEST previas en el log para evitar falsos positivos
if [ -f "$LOG_FILE" ]; then
    sed -i 's/\[AUTOTEST\]/\[PREV-AUTOTEST\]/g' "$LOG_FILE" 2>/dev/null || true
    START_LINE=$(($(wc -l < "$LOG_FILE") + 1))
else
    START_LINE=1
fi

# 2. Configurar archivo de prueba en SDMC
if [ "$BENCH" = "1" ]; then
    rm -f "$CFG_FILE" 2>/dev/null || true
    echo "[AUTOTEST-RUNNER] Video bench: pass = videobench.log says done with no decoding error"
elif [ "$SMOKE" = "1" ]; then
    rm -f "$CFG_FILE" "$(dirname "$NRO_PATH")/autotest.cfg" 2>/dev/null || true
    SMOKE_STAMP=$(mktemp)
    echo "[AUTOTEST-RUNNER] Public build smoke test: no autotest.cfg; pass = still running after ${TIMEOUT_SEC}s, no native crash, nothing written under logs/"
else
    echo "$SCENARIO" > "$CFG_FILE"
    echo "$SCENARIO" > "$(dirname "$NRO_PATH")/autotest.cfg" 2>/dev/null || true
    echo "[AUTOTEST-RUNNER] Prepared autotest scenario '$SCENARIO' at $CFG_FILE (Start line: $START_LINE)"
fi

# Citron se lanza a traves del wrapper binfmt de AppImageLauncher: el emulador real es un proceso
# nieto (/tmp/.mount_citro*/bin/citron, ~10 GB RSS). Matar solo $! lo dejaba huerfano, por eso se
# lanza en su propio grupo de procesos (setsid) y se elimina el grupo completo.
kill_citron() {
    if [ -n "$CITRON_PID" ]; then
        kill -TERM -- "-$CITRON_PID" 2>/dev/null || true
        sleep 2
        kill -KILL -- "-$CITRON_PID" 2>/dev/null || true
    fi
    # Red de seguridad: cualquier instancia que siga ejecutando este NRO.
    pkill -KILL -f "bin/citron -g $NRO_PATH" 2>/dev/null || true
    pkill -KILL -f "citron.*AppImage -g $NRO_PATH" 2>/dev/null || true
}

cleanup() {
    echo "[AUTOTEST-RUNNER] Cleaning up autotest configuration and processes..."
    rm -f "$CFG_FILE"
    rm -f "$(dirname "$NRO_PATH")/autotest.cfg" 2>/dev/null || true
    kill_citron
    if pgrep -f "bin/citron -g $NRO_PATH" > /dev/null 2>&1; then
        echo "[AUTOTEST-RUNNER] WARNING: a Citron process is still alive, kill it manually!"
    fi
}
trap cleanup EXIT INT TERM HUP

# 2b. No arrancar si ya hay un Citron vivo con este NRO (instancias huerfanas agotan la RAM del host).
if pgrep -f "bin/citron -g $NRO_PATH" > /dev/null 2>&1; then
    echo "[AUTOTEST-RUNNER] Found a running Citron instance for this NRO, terminating it first..."
    pkill -KILL -f "bin/citron -g $NRO_PATH" 2>/dev/null || true
    sleep 1
fi

# 3. Lanzar Citron con Funkin.nro usando flag -g, en un grupo de procesos propio
echo "[AUTOTEST-RUNNER] Launching Citron with $(basename "$NRO_PATH") (Timeout: ${TIMEOUT_SEC}s)..."
CITRON_LOG_FILE="$HOME/.local/share/citron/log/citron_log.txt"
setsid "$CITRON_BIN" -g "$NRO_PATH" > "${CITRON_STDOUT:-/dev/null}" 2>&1 &
CITRON_PID=$!

echo "[AUTOTEST-RUNNER] Citron running with PID $CITRON_PID. Monitoring $LOG_FILE..."

ELAPSED=0
STATUS="TIMEOUT"

while [ "$ELAPSED" -lt "$TIMEOUT_SEC" ]; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))

    if ! kill -0 "$CITRON_PID" 2>/dev/null; then
        echo "[AUTOTEST-RUNNER] WARNING: Citron exited prematurely."
        STATUS="CRASHED"
        break
    fi

    if [ "$BENCH" = "1" ] && [ -f "$LOG_FILE" ]; then
        NEW_LINES=$(tail -n +"$START_LINE" "$LOG_FILE" 2>/dev/null || true)
        if echo "$NEW_LINES" | grep -q " error="; then
            STATUS="FAILED"
            break
        fi
        if echo "$NEW_LINES" | grep -q "\[VIDEOBENCH\] done"; then
            STATUS="SUCCESS"
            break
        fi
    elif [ "$SMOKE" = "0" ] && [ -f "$LOG_FILE" ]; then
        NEW_LINES=$(tail -n +"$START_LINE" "$LOG_FILE" 2>/dev/null || true)

        if echo "$NEW_LINES" | grep -q "COMPLETED SUCCESSFULLY"; then
            STATUS="SUCCESS"
            break
        fi

        if echo "$NEW_LINES" | grep -q "TEST FAILED"; then
            STATUS="FAILED"
            break
        fi

        if echo "$NEW_LINES" | grep -q -E "UNCAUGHT ERROR|Null Object Reference|CRASH"; then
            STATUS="ERROR"
            break
        fi
    fi

    # Crash nativo del guest (abort/BRK, Unmapped access): el juego queda congelado sin escribir mas trazas.
    if [ "$ELAPSED" -ge 6 ] && [ -f "$CITRON_LOG_FILE" ] && grep -q -E "ExceptionRaised|Unmapped (Read|Write)" "$CITRON_LOG_FILE" 2>/dev/null; then
        STATUS="NATIVE_CRASH"
        cp "$CITRON_LOG_FILE" "$SDMC_DIR/logs/citron-native-crash-$(date +%Y%m%d-%H%M%S).log" 2>/dev/null || true
        break
    fi
done

if [ "$SMOKE" = "1" ] && [ "$STATUS" = "TIMEOUT" ]; then
    WRITTEN=$(find "$SDMC_DIR/logs" -newer "$SMOKE_STAMP" -type f 2>/dev/null || true)
    if [ -n "$WRITTEN" ]; then
        echo "[AUTOTEST-RUNNER] The public build wrote under logs/:"
        echo "$WRITTEN"
        STATUS="WROTE_LOGS"
    else
        STATUS="SUCCESS"
    fi
fi
[ -n "${SMOKE_STAMP:-}" ] && rm -f "$SMOKE_STAMP"

echo "[AUTOTEST-RUNNER] Test run finished with status: $STATUS (Elapsed: ${ELAPSED}s)"
echo "--------------------------------------------------"
echo "TELEMETRY LOG SUMMARY:"
echo "--------------------------------------------------"
if [ -f "$LOG_FILE" ]; then
    tail -n +"$START_LINE" "$LOG_FILE" | grep -E "AUTOTEST|NXVideoPlayer|Sheet|AUDIO|STAGE|MEMORY|VIDEOBENCH" || true
fi
echo "--------------------------------------------------"
if [ "$STATUS" = "NATIVE_CRASH" ]; then
    echo "NATIVE CRASH BACKTRACE (decoded):"
    python3 "$(dirname "$0")/decode_switch_crash.py" "$CITRON_LOG_FILE" 2>&1 | tail -n 60 || true
    echo "--------------------------------------------------"
fi

if [ "$STATUS" = "SUCCESS" ]; then
    echo "[AUTOTEST-RUNNER] TEST PASSED SUCCESSFULLY!"
    exit 0
else
    echo "[AUTOTEST-RUNNER] TEST FAILED WITH STATUS: $STATUS"
    exit 1
fi
