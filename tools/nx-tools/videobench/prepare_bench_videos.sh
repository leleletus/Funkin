#!/usr/bin/env bash
# Builds the 7 cutscene videos for the VIDEO_BENCH decoder bench from the official assets submodule:
# H.264 1280x720 MP4 without audio, as the Switch player would play them.
#   <name>.mp4     H.264 sources remuxed as they are; 2Hot (HEVC 1080p) and Darnell (VP9) re-encoded (CRF 18)
#   <name>.fd.mp4  every video re-encoded with x264 "-tune fastdecode" (no CABAC, no deblocking)
#   <name>.orig.*  the official file as it is (video track only, same container)
# Output (not versioned): export/nx-generated/videobench/romfs/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SRC="$ROOT/assets/videos/videos"
OUT="$ROOT/export/nx-generated/videobench/romfs"
NAMES=(ughCutscene gunsCutscene stressCutscene stressPicoCutscene darnellCutscene 2hotCutscene blazinCutscene)
X264=(-c:v libx264 -preset slow -crf 18 -profile:v high -pix_fmt yuv420p)

mkdir -p "$OUT"
for name in "${NAMES[@]}"; do
  src=""
  for ext in mp4 mkv webm; do [[ -f "$SRC/$name.$ext" ]] && src="$SRC/$name.$ext" && break; done
  [[ -n "$src" ]] || { echo "[videobench] missing source for $name" >&2; exit 1; }
  codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,height -of csv=p=0 "$src")"
  if [[ ! -f "$OUT/$name.mp4" ]]; then
    if [[ "$codec" == "h264,720" ]]; then
      ffmpeg -y -v error -i "$src" -map 0:v:0 -c:v copy -an -movflags +faststart "$OUT/$name.mp4"
    else
      ffmpeg -y -v error -i "$src" -map 0:v:0 -vf scale=1280:720:flags=lanczos "${X264[@]}" -an -movflags +faststart "$OUT/$name.mp4"
    fi
  fi
  if [[ ! -f "$OUT/$name.fd.mp4" ]]; then
    ffmpeg -y -v error -i "$src" -map 0:v:0 -vf scale=1280:720:flags=lanczos "${X264[@]}" -tune fastdecode -an -movflags +faststart "$OUT/$name.fd.mp4"
  fi
  orig="$OUT/$name.orig.${src##*.}"
  [[ -f "$orig" ]] || ffmpeg -y -v error -i "$src" -map 0:v:0 -c:v copy -an "$orig"
  for f in "$OUT/$name.mp4" "$OUT/$name.fd.mp4" "$orig"; do
    printf '[videobench] %-32s %6s  %s frames\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
      "$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$f")"
  done
done
