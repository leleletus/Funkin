#!/usr/bin/env bash
# ==============================================================================
# Detects .ogg files that overflow lime-nx's OGG decoder (INC-37).
#
# lime OGG::Decode allocates ov_pcm_total * channels * 2 bytes and then calls ov_read until EOF
# without checking the remaining space. Files that decode more samples than they declare write past
# the buffer and corrupt the heap (native crash on Switch). This tool compiles a host checker against
# libvorbisfile (same library, same API) and scans the given paths (default: assets/).
#
# Usage: ./tools/nx-tools/check_ogg_overflow.sh [path ...]
# Requires: gcc and libvorbis development files on the host.
# ==============================================================================
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${TMPDIR:-/tmp}/check_ogg_overflow_$$"
trap 'rm -f "$BIN"' EXIT
gcc -O2 -o "$BIN" "$DIR/check_ogg_overflow.c" -lvorbisfile

PATHS=("$@")
[ ${#PATHS[@]} -eq 0 ] && PATHS=("$DIR/../../assets")

BAD=0
TOTAL=0
while IFS= read -r -d '' f; do
    TOTAL=$((TOTAL + 1))
    RESULT="$("$BIN" "$f")"
    case "$RESULT" in
        ok*) ;;
        *) echo "$RESULT  $f"; BAD=$((BAD + 1)) ;;
    esac
done < <(find "${PATHS[@]}" -name "*.ogg" -print0)

echo "Checked $TOTAL .ogg files, $BAD overflow(s)."
[ "$BAD" -eq 0 ]
