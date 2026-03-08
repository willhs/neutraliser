# Performance Benchmark Plan

## Problems with Previous Testing

1. **Files skip processing** — existing library files are often already at target LUFS, cached, or fast-verified. We can't guarantee real work happens.
2. **Single-file tests hide the staging benefit** — one FFmpeg process saturates the CPU (~100%) so I/O is never the bottleneck. `--local-stage` helps when *multiple* processes compete for SMB bandwidth.
3. **No timing breakdown** — we can't tell how long each phase takes (stage-in, measure, normalize, stage-out).
4. **Different files across runs** — codec, bitrate, duration, and loudness all vary, making comparisons meaningless.

## Test Design

### 1. Generate Synthetic Test Files

Create test files with **known loudness far from target** so processing is always triggered. Generate them locally, then copy to NAS.

```bash
# Generate a 1GB test file at -30 LUFS (10 LU from -20 target, guaranteed to need processing)
# Uses lavfi to create synthetic audio + video
ffmpeg -f lavfi -i "sine=frequency=440:duration=600" \
       -f lavfi -i "testsrc2=duration=600:size=1920x1080:rate=24" \
       -af "volume=-30dB" \
       -c:v libx264 -preset ultrafast -crf 23 \
       -c:a aac -b:a 256k \
       -t 600 \
       benchmark/test_source.mp4

# Verify loudness
ffmpeg -hide_banner -nostats -i benchmark/test_source.mp4 \
       -map a:0 -af "loudnorm=I=-20:print_format=json" -f null - 2>&1 | grep input_i
```

### 2. Deploy Test Files to NAS

Create multiple copies for parallel testing:

```bash
mkdir -p /mnt/nas/media/movies/_benchmark_test
for i in 1 2 3 4 5 6; do
  cp benchmark/test_source.mp4 "/mnt/nas/media/movies/_benchmark_test/test_${i}.mp4"
done
```

### 3. Test Matrix

Run each scenario **sequentially** (one at a time, full system resources):

| # | Flags | Files | What it tests |
|---|---|---|---|
| A | *(none)* | 1 file | Baseline: two-pass over NAS, single file |
| B | `--fast` | 1 file | Fast vs two-pass (same I/O, fewer passes) |
| C | `--local-stage` | 1 file | Staging overhead vs NAS direct (single file) |
| D | `--fast --local-stage` | 1 file | Combined, single file |
| E | *(none)* | 6 files | Baseline: two-pass over NAS, parallel |
| F | `--fast` | 6 files | Fast mode, parallel (less CPU per file) |
| G | `--local-stage` | 6 files | Staging, parallel (**this is the key test**) |
| H | `--fast --local-stage` | 6 files | Combined, parallel |

### 4. What to Measure

For each run, capture:
- **Wall clock time** (total elapsed)
- **CPU usage** (`%cpu` from `time`)
- **Outcome** (did it actually process or skip?)

### 5. Critical Controls

- `--no-cache --no-fast-verify` on every run (prevent skipping)
- `--replace` to avoid `_normalized` files accumulating
- **Re-copy test files from source before each run** (reset to known state)
- Only one benchmark running at a time (no background competition)
- Verify test files need processing: check loudness before first run

### 6. Potential Issues to Watch For

- **Disk space**: 6 x 1GB = 6GB on NAS + staging copies on NVMe. NVMe has ~200GB free so fine, but clean up between runs.
- **FFmpeg process count**: parallel mode auto-detects threads. With 6 files on a 6-core i5, each FFmpeg gets ~1 core. This is where SMB contention should appear.
- **NAS caching**: the NAS may cache recently-read files in RAM, making second reads faster. Re-copying from source mitigates this, but the NAS OS cache is out of our control. Running tests in order (baseline first) gives baseline the "cold cache" disadvantage, which is conservative (makes improvements look smaller, not larger).
- **Test file codec**: use `libx264 -preset ultrafast` to minimize CPU decode time, making I/O a larger proportion of total time. This gives staging its best chance to show a difference.
- **Audio codec**: use AAC since it's fast to encode. The bottleneck we're testing is file I/O, not audio encoding.

## Running the Benchmark

```bash
cd /home/will/projects/neutraliser
bash benchmark/run.sh
```

The script handles file setup, sequential execution, cleanup, and timing output.

## Expected Results

- **Single-file**: `--fast` should save ~30-50% (skips measurement pass). `--local-stage` may show minimal benefit (CPU-bound with one process).
- **Multi-file parallel**: `--local-stage` should show significant improvement because 6 FFmpeg processes reading/writing over SMB simultaneously will contend for bandwidth. Local staging serializes NAS access (one copy-in, one copy-out) and parallelizes the CPU-heavy processing on local disk.
- **Combined**: `--fast --local-stage` parallel should be fastest overall.

If single-file `--fast` doesn't show improvement, the loudnorm filter itself is the CPU bottleneck (not the file read), and `--fast` only saves I/O time from skipping one read pass.
