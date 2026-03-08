---
type: adr
status: accepted
owner: will
contributors: []
updated: 2026-03-08
review_cycle: 90d
agent_write: true
links: ["docs/tasks/0005-local-staging-and-fast-mode/task.md"]
summary: "Add --fast and --local-stage flags to reduce processing time on NAS setups"
tags: ["performance", "ffmpeg", "staging"]
---

# Context

Processing video files on network-attached storage (NAS over SMB/NFS) is slow. Each file requires two full FFmpeg passes: a measurement pass (read-only) and a normalization pass (read + write). For a typical 2GB movie file, this takes 20-30 minutes over a ~110 MB/s SMB link.

Two hypotheses were tested:
1. **Single-pass loudnorm** (`--fast`) — skip the measurement pass and use FFmpeg's dynamic loudnorm mode, halving the number of file reads.
2. **Local staging** (`--local-stage`) — copy files to fast local NVMe before processing, then copy results back, avoiding repeated slow I/O over the network.

# Decision

Implement both flags as independent, opt-in CLI options:

- **`--fast`** — uses `loudnorm` without pre-measured values (dynamic mode, `linear=false` implicitly). One FFmpeg pass instead of two. Trades accuracy for speed — dynamic mode adjusts gain on-the-fly rather than using a constant linear offset calculated from the measurement pass.
- **`--local-stage`** — `LocalStager` copies files to `/tmp/neutraliser_staging/`, processing happens on local disk, results are copied back. Cache sidecars still reference the original path so cache hits work across staged/unstaged runs.

# Benchmark Results

Tested on an i5-8600T (6 cores), NAS over gigabit SMB (~110 MB/s). Test file: 932MB synthetic MP4, 10 minutes, x264 ultrafast, at -51.8 LUFS (needs 31.8 LU adjustment — guaranteed to process, not skip).

### Single File

| Mode | Time | vs Baseline |
|---|---|---|
| Baseline (two-pass, NAS) | 0:55 | — |
| `--fast` (single-pass, NAS) | 0:38 | **-30%** |
| `--local-stage` (two-pass, NVMe) | 0:54 | -2% |
| `--fast --local-stage` | 0:41 | -25% |

### Parallel (6 files, 5.5GB total)

| Mode | Time | vs Baseline |
|---|---|---|
| Baseline (two-pass, NAS) | 2:48 | — |
| `--fast` (single-pass, NAS) | 1:46 | **-37%** |
| `--local-stage` (two-pass, NVMe) | 3:00 | +7% (slower) |
| `--fast --local-stage` | 2:29 | -11% |

### Analysis

- **`--fast` is the clear winner** — consistent 30-37% improvement by eliminating the measurement pass. The CPU savings from skipping one full decode are real.
- **`--local-stage` showed no benefit** on this setup. SMB at ~110 MB/s delivers data faster than the CPU can decode it, making processing CPU-bound not I/O-bound. The staging copy overhead (10-20s per file) eats any I/O savings. In parallel, concurrent stage-in copies compete for SMB bandwidth, making it slightly *slower*.
- **`--local-stage` may help** on slower networks (WiFi, WAN, sub-50 MB/s NAS), with much larger files, or with high-latency mounts where FFmpeg's random seeks are penalized.

Full benchmark script and raw results are in `benchmark/`.

# Consequences (Positive/Negative)

**Positive:**
- `--fast` delivers meaningful speedup with minimal code complexity
- Both features are opt-in with no impact on default behaviour
- `LocalStager` is available for slower network scenarios without code changes
- Benchmark harness (`benchmark/run.sh`) enables reproducible performance testing

**Negative:**
- `--fast` produces slightly less accurate normalization (dynamic vs linear mode) — acceptable for casual listening, not ideal for broadcast compliance
- `--local-stage` requires sufficient local disk space for the largest file being processed
- `--local-stage` showed no benefit on the primary target setup (gigabit SMB), so it may be a rarely-used feature

# Alternatives Considered

- **Auto-detecting network mounts** — detect SMB/NFS and stage automatically. Rejected: platform-specific, fragile, and benchmarks showed staging doesn't help on fast LANs anyway. Explicit flag is simpler.
- **Pipelining network transfers with processing** (prefetch next file while processing current) — more complex, would require changes to the parallel processing architecture. Deferred.
- **Configurable staging directory** — hardcoded to `$TMPDIR/neutraliser_staging` for simplicity. Could be parameterized later if needed.
- **Removing `--local-stage` after benchmarks** — decided to keep it since it's small (~30 lines), well-tested, opt-in, and may help on different network setups.

# Links

- Task spec: `docs/tasks/0005-local-staging-and-fast-mode/task.md`
- Benchmark script: `benchmark/run.sh`
- Benchmark results: `benchmark/results_20260308_051318.txt`
- Implementation: `lib/neutraliser/local_stager.rb`, `lib/neutraliser/ffmpeg_wrapper.rb` (`apply_normalization_single_pass`)

### Change Log
- 2026-03-08 (agent:implement-plan): created with benchmark data
