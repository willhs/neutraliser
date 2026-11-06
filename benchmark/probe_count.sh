#!/usr/bin/env bash
# Counts the ffprobe/ffmpeg runs one `process --replace` costs, by logging every call through a
# shim on PATH. Method from docs/research/architecture-review-2026-11.md. Prints the log and a
# per-tool count; the number to watch is "ffprobe". A file is the 2-audio-track mkv (English
# default + Spanish, AC-3) the note used, quiet enough that it is really normalised.
#
#   benchmark/probe_count.sh                 # from the repo root, needs ffmpeg, ffprobe and bundler
#   RUNS=2 benchmark/probe_count.sh          # count only the last of 2 runs (a file already done: no probes)
#   benchmark/probe_count.sh --local-stage   # extra args go to `process`
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REAL_FFMPEG="$(command -v ffmpeg)"
REAL_FFPROBE="$(command -v ffprobe)"
LOG="$WORK/calls.log"

mkdir -p "$WORK/shims" "$WORK/lib"
for tool in ffmpeg ffprobe; do
  real="$REAL_FFMPEG"; [ "$tool" = ffprobe ] && real="$REAL_FFPROBE"
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexec "%s" "$@"\n' "$tool" "$LOG" "$real" > "$WORK/shims/$tool"
  chmod +x "$WORK/shims/$tool"
done

"$REAL_FFMPEG" -v error -y \
  -f lavfi -i "testsrc2=duration=20:size=320x240:rate=24" \
  -f lavfi -i "sine=frequency=440:duration=20,volume=0.05" \
  -f lavfi -i "sine=frequency=330:duration=20,volume=0.05" \
  -map 0:v -map 1:a -map 2:a -c:v libx264 -preset ultrafast -c:a ac3 \
  -metadata:s:a:0 language=eng -metadata:s:a:1 language=spa \
  -disposition:a:0 default -disposition:a:1 0 "$WORK/lib/film.mkv"

for run in $(seq 1 "${RUNS:-1}"); do
  : > "$LOG"
  (cd "$ROOT" && PATH="$WORK/shims:$PATH" bundle exec bin/neutraliser process "$WORK/lib" --replace --no-cache "$@") > "$WORK/run.out" 2>&1 \
    || { cat "$WORK/run.out"; exit 1; }
done

cut -c1-150 "$LOG"
echo "---"
for tool in ffprobe ffmpeg; do
  echo "$tool: $(grep -c "^$tool " "$LOG" || true)  (of which -version: $(grep -c "^$tool -version" "$LOG"))"
done
