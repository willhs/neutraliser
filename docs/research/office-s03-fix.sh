#!/bin/sh
# Re-level the four unprocessed DTS-HD episodes of The Office (US) S03 on the NAS.
# The same `docker run` as media-server's neutralise-driver.sh run_one(), plus
# --allow-codec-change --allow-dynamic for these four files only. Run it ON the NAS
# (see docs/research/office-s03-volume-spread-2026-11.md for the one-line ssh form).
#
# usage: STAGE=<stage dir> MEDIA_ROOT=<media root> LOCK=<lock, optional> \
#        sh office-s03-fix.sh SHOW_DIR BACKUP_DIR [--dry-run]
#   STAGE      the driver's stage dir (mounted at /stage, as the driver does)
#   MEDIA_ROOT the library root, mounted at the same path inside the container
#   SHOW_DIR   the show folder, e.g. "<media root>/tv/The Office (US)"
#   BACKUP_DIR where the four originals are copied first (kept; delete when happy)
#   LOCK       container path of the run lock (default: the driver's /stage/.neutralise.lock)
set -eu
: "${STAGE:?}" "${MEDIA_ROOT:?}"
SHOW=$1; BACKUP=$2; shift 2
IMAGE=ghcr.io/willhs/neutraliser:latest
LOCK=${LOCK:-/stage/.neutralise.lock}

mkdir -p "$BACKUP"
for E in 01 04 06 17; do
  F=$(ls "$SHOW/Season 3/"The.Office.US.S03E$E.*HEVC*.mkv)
  echo "== S03E$E: $F"
  [ "${1:-}" = "--dry-run" ] || cp -p "$F" "$BACKUP/"
  start=$(date +%s)
  sudo docker run --rm -v "$STAGE:/stage" -v "$STAGE:$STAGE" -v "$MEDIA_ROOT:$MEDIA_ROOT" \
    -e NEUTRALISER_ANALYSIS_TIMEOUT=7200 -e NEUTRALISER_NORMALIZATION_TIMEOUT=7200 \
    "$IMAGE" process "$F" --replace --tolerance 2 --min-gain 1 \
    --no-fast-verify --no-cache --lock-file "$LOCK" \
    --min-free-gb 40 --abort-free-gb 20 \
    --allow-codec-change --allow-dynamic "$@" </dev/null
  echo "== S03E$E took $(( $(date +%s) - start )) s"
done
