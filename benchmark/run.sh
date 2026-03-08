#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/mnt/nas/media/movies/_benchmark_test"
LOCAL_SOURCE="benchmark/test_source.mp4"
FILE_COUNT=6
RESULTS_FILE="benchmark/results_$(date +%Y%m%d_%H%M%S).txt"

# --- Setup ---

generate_test_file() {
  if [[ -f "$LOCAL_SOURCE" ]]; then
    echo "Test source already exists, checking loudness..."
  else
    echo "Generating 10-minute test file with audio at -30 LUFS..."
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=600" \
           -f lavfi -i "testsrc2=duration=600:size=1920x1080:rate=24" \
           -af "volume=-30dB" \
           -c:v libx264 -preset ultrafast -crf 23 \
           -c:a aac -b:a 256k \
           -t 600 \
           "$LOCAL_SOURCE" 2>/dev/null
    echo "Generated: $(du -h "$LOCAL_SOURCE" | cut -f1)"
  fi

  echo "Verifying loudness..."
  LUFS=$(ffmpeg -hide_banner -nostats -i "$LOCAL_SOURCE" \
         -map a:0 -af "loudnorm=I=-20:print_format=json" \
         -f null - 2>&1 | grep '"input_i"' | grep -oP '[\-0-9.]+')
  echo "Test file loudness: ${LUFS} LUFS (target: -20.0, needs processing: yes)"

  # Sanity check - file must need processing
  DIFF=$(echo "$LUFS + 20" | bc -l)
  ABS_DIFF=$(echo "${DIFF#-}")
  if (( $(echo "$ABS_DIFF < 1.0" | bc -l) )); then
    echo "ERROR: Test file is already near target! Regenerate it."
    exit 1
  fi
}

deploy_to_nas() {
  echo "Deploying $FILE_COUNT test files to NAS..."
  mkdir -p "$BENCH_DIR"
  for i in $(seq 1 "$FILE_COUNT"); do
    cp "$LOCAL_SOURCE" "$BENCH_DIR/test_${i}.mp4"
  done
  echo "Deployed to $BENCH_DIR"
  ls -lh "$BENCH_DIR"
}

reset_nas_files() {
  echo "  Resetting test files on NAS..."
  rm -f "$BENCH_DIR"/test_*_normalized.mp4
  for i in $(seq 1 "$FILE_COUNT"); do
    cp "$LOCAL_SOURCE" "$BENCH_DIR/test_${i}.mp4"
  done
}

cleanup_staging() {
  rm -f /tmp/neutraliser_staging/* 2>/dev/null || true
}

# --- Benchmark Runners ---

run_single() {
  local label="$1"
  shift
  local flags=("$@")

  echo ""
  echo "========================================"
  echo "=== $label ==="
  echo "========================================"

  reset_nas_files
  cleanup_staging
  sleep 2  # let NAS settle

  local file="$BENCH_DIR/test_1.mp4"
  echo "  File: $file"
  echo "  Flags: ${flags[*]:-none}"

  { time bundle exec neutraliser process \
      --no-cache --no-fast-verify --replace \
      "${flags[@]}" "$file" 2>&1 ; } 2>&1 | tee -a "$RESULTS_FILE"
}

run_parallel() {
  local label="$1"
  shift
  local flags=("$@")

  echo ""
  echo "========================================"
  echo "=== $label ==="
  echo "========================================"

  reset_nas_files
  cleanup_staging
  sleep 2

  echo "  Dir: $BENCH_DIR ($FILE_COUNT files)"
  echo "  Flags: ${flags[*]:-none}"

  { time bundle exec neutraliser process \
      --no-cache --no-fast-verify --replace \
      "${flags[@]}" "$BENCH_DIR" 2>&1 ; } 2>&1 | tee -a "$RESULTS_FILE"
}

# --- Main ---

echo "=== Neutraliser Performance Benchmark ===" | tee "$RESULTS_FILE"
echo "Date: $(date)" | tee -a "$RESULTS_FILE"
echo "Host: $(hostname)" | tee -a "$RESULTS_FILE"
echo "" | tee -a "$RESULTS_FILE"

generate_test_file
deploy_to_nas

echo "" | tee -a "$RESULTS_FILE"
echo "--- SINGLE FILE TESTS ---" | tee -a "$RESULTS_FILE"

run_single "A: Baseline (two-pass, NAS)"
run_single "B: --fast (single-pass, NAS)" --fast
run_single "C: --local-stage (two-pass, NVMe)" --local-stage
run_single "D: --fast --local-stage (both)" --fast --local-stage

echo "" | tee -a "$RESULTS_FILE"
echo "--- PARALLEL ($FILE_COUNT FILE) TESTS ---" | tee -a "$RESULTS_FILE"

run_parallel "E: Baseline parallel (two-pass, NAS)"
run_parallel "F: --fast parallel (single-pass, NAS)" --fast
run_parallel "G: --local-stage parallel (two-pass, NVMe)" --local-stage
run_parallel "H: --fast --local-stage parallel (both)" --fast --local-stage

# --- Cleanup ---

echo "" | tee -a "$RESULTS_FILE"
echo "=== Benchmark Complete ===" | tee -a "$RESULTS_FILE"
echo "Results saved to: $RESULTS_FILE"
echo ""
echo "Cleaning up test files on NAS..."
rm -rf "$BENCH_DIR"
cleanup_staging
echo "Done."
