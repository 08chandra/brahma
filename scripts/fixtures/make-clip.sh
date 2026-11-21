#!/bin/bash
# Writes scripts/fixtures/clip-9x16.mp4 (Plan 4a Task 9b, fix 14): a 2 s 1080×1920 H.264 clip the seed publishes as
# AR-3 "Launch reel", so the ARTIFACTS tab has a phone-framed video. ffmpeg (with drawtext) makes it when present; otherwise,
# or when that ffmpeg lacks the filter, the Swift fallback (MakeClip.swift: AVAssetWriter, 1 fps solid frames) does. The
# result must stay small enough to commit: at most MAX_BYTES (300 KB), checked with stat.
set -euo pipefail
cd "$(dirname "$0")"
OUT="clip-9x16.mp4"
MAX_BYTES=307200

made=""
if command -v ffmpeg >/dev/null 2>&1; then
  if ffmpeg -hide_banner -loglevel error -y -f lavfi \
      -i "color=c=0x1A2129:s=1080x1920:d=2,drawtext=text='Launch':fontcolor=0xE6EBF0:fontsize=120:x=(w-tw)/2:y=(h-th)/2" \
      -c:v libx264 -pix_fmt yuv420p -preset veryslow -crf 40 -an -movflags +faststart "$OUT" 2>/dev/null; then
    made="ffmpeg"
  else
    echo "make-clip.sh: ffmpeg could not make the clip (no drawtext filter?); using the Swift fallback" >&2
    rm -f "$OUT"
  fi
fi
if [ -z "$made" ]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  swift MakeClip.swift "$OUT"
  made="swift"
fi

SIZE="$(stat -f%z "$OUT")"
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "make-clip.sh: $OUT is $SIZE bytes, over the $MAX_BYTES cap" >&2
  exit 1
fi
echo "wrote $OUT ($SIZE bytes, $made)"
