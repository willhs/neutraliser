---
type: architecture
status: draft
owner: will
contributors: []
updated: 2026-10-15
review_cycle: 90d
agent_write: false
links: []
summary: "System diagram and flows"
tags: []
---

## Context / Purpose

Describe the end-to-end system shape so contributors understand integration points.

## Current State

### Normalisation Pipeline

```
Input File
    │
    ▼
┌─────────────────────┐
│  Processor          │  Orchestrates the pipeline per file
│                     │
│  ┌───────────────┐  │
│  │ SkipDecider   │  │  Single "already normalised?" authority (in-file
│  └───────┬───────┘  │  stamp / sidecar cache, quick LUFS sample fallback)
│          ▼          │
│  ┌───────────────┐  │
│  │ AudioAnalyser │  │  Full loudnorm measurement (with sidecar cache)
│  └───────┬───────┘  │
│          ▼          │
│  ┌───────────────┐  │
│  │ FFmpegWrapper │  │  Measure → apply gain, writing the Stamp tags
│  └───────┬───────┘  │
│          ▼          │
│  ┌───────────────┐  │
│  │ FileManager   │  │  Atomic replace or _normalized copy
│  └───────────────┘  │
└─────────────────────┘
    │
    ▼
Output File
```

### Audio Codec Selection

When re-encoding normalised audio, the codec and bitrate are selected to match the source as closely as possible:

1. **Probe** — `detect_audio_tracks` reads codec, profile, bitrate, sample rate, channel count and track title via ffprobe. This happens once per file, before measuring.
2. **Match** — `select_output_codec` tries to re-encode to the same codec at `max(source_bitrate, quality_floor)`, capped at a per-codec maximum.
3. **Fallback** — non-encodable codecs (DTS, TrueHD) fall back to FLAC in MKV or EAC3/AC3 in MP4. Lossless sources stay lossless when the container supports it.
4. **Log** — every normalisation logs the decision (e.g., `Audio: ac3 448k -> ac3 448k`).

See [ADR-0001](adr/0001-smart-codec-selection.md) for the full rationale.

### Object audio is skipped by default

ffmpeg can't encode Atmos or DTS:X object metadata, so re-encoding the primary track would flatten it. `ObjectAudio.detect` (`lib/neutraliser/object_audio.rb`) checks the probed stream `profile` (FFmpeg 7.1+ names `Dolby Digital Plus + Dolby Atmos`, `Dolby TrueHD + Dolby Atmos`, `DTS-HD MA + DTS:X`). libavcodec sets these profiles while decoding, so for an E-AC3/TrueHD/DTS track whose name or title says Atmos/DTS:X but whose profile doesn't, it checks again on a slice cut from mid-file. A name alone never triggers a skip. Object audio returns `skipped` / `object_audio` before the loudness pass. The skip isn't stamped in the sidecar, and `--resume --allow-object-audio-loss` reprocesses those files. `--allow-object-audio-loss` processes them anyway, with a warning. See [object-audio-detection](../research/object-audio-detection.md).

### Constant gain by default, dynamic opt-in

The default normalisation pass is a constant `volume=` gain (`FFmpegWrapper.build_volume_gain_filter`), capped so true peak stays at or below the profile TP. Quiet-but-peaky files land shy of target; `apply_normalization` returns `shortfall_lu` and the Processor logs it. `--allow-dynamic` switches to the two-pass `loudnorm` filter, which may fall back to dynamic compression; profiles with `dynamic: true` (`night`) imply it. Every result carries `normalization_type` (Linear/Dynamic); the run summary reports `linear`/`dynamic` counts and each Dynamic file logs a warning. `--linear-only` is a deprecated no-op.

### Every change is recorded in the file (Stamp)

The normalise pass writes a `Stamp` (`lib/neutraliser/stamp.rb`) as `NEUTRALISER_*` tags in the same ffmpeg command: on the normalised audio stream (`-metadata:s:a:0`) and on the container (`-metadata`). They come after the explicit per-stream `-map_metadata` mappings, so language and title tags are kept and the stamp is added on top. MP4/M4V/MOV only keep custom keys at container level, and only with `-movflags +use_metadata_tags`, so that flag is added for them. MKV/WebM/FLV/WMV keep the tags; AVI drops them, and there the sidecar is the only record. `FFmpegWrapper.read_stamp` prefers the stream tags and falls back to the container. The schema is in [data_contracts](../ops/data_contracts.md).

The mode tag has to be written before ffmpeg runs, but with `--allow-dynamic` loudnorm only says afterwards whether it stayed linear. So `predict_loudnorm_type` copies loudnorm's own rule (valid measured values, gain fits under the true-peak ceiling, source LRA ≤ target LRA). If loudnorm's summary disagrees, `restamp` stream-copies the output once with corrected tags before it is committed. The tags never claim the wrong mode. Constant gain (the default) is always linear and `--fast` is always dynamic, so neither needs a prediction.

`neutraliser report PATH` (`lib/neutraliser/report.rb`) reads the stamps back to count linear / dynamic / untouched files, the profile mix and the recipe mix.

### Recipes, left-alone records and the remote-free rate

- **Recipe** (`recipe.rb`): a version number for the leveling method, stamped as `NEUTRALISER_RECIPE` and kept in the sidecar. Profile names say where to aim; the recipe says how. `SkipDecider` ignores the recipe by default, so changing the default can never re-level a library by accident, and takes `redo_recipes:` (`process --redo-recipe`) as the deliberate re-run. Files from before recipes are `unversioned`: valid, counted, and redoable. The current recipe can't be redone (every file it wrote would qualify again).
- **LeftRecord** (`left_record.rb`): why a file was looked at and not re-encoded (peak-limited, object audio, codec change, within tolerance), with its measured levels when there are any. A stamp needs a re-encode, so the record lives in the sidecar, shaped so it can't be mistaken for "done" (no top-level `profile`). `Report` reads it via `SkipDecider.left_record_for`.
- **FinalLevels / RemoteFreeRate** (`remote_free_rate.rb`): where a file ends up (integrated loudness, LRA, target) and the share of files within 2 LU of target and at or under an LRA limit (12 LU). Levels are *computed* from the record by default (constant gain: measured + gain, range unchanged; dynamic: the target, range capped at the profile's; untouched: as measured) or *measured* by reading the file (`report --measure`). A file whose levels the record can't give, such as a `limited` one, is counted as not judged rather than guessed: a limiter run aimed at -20 LUFS measured -26.
- **RateHarness** (`rate_harness.rb`, `neutraliser rate-sample`): an equal share of a random sample per root, copied to a scratch folder outside the library, run through the processor with `replace`, judged by `Report`. The library is only read; a work folder inside a root is refused.

### Performance Flags

Two optional flags reduce per-file processing time. See [ADR-0002](adr/0002-performance-flags.md) for rationale and benchmark data.

- **`--fast`** — uses FFmpeg's single-pass loudnorm (dynamic mode) instead of the default constant-gain pass. Always dynamic, so it is refused unless `--allow-dynamic` is given or the profile is dynamic (`night`). Skips the measurement pass entirely. Benchmarked at **30-37% faster**. Slightly less accurate — uses dynamic gain adjustment rather than a constant linear offset.
- **`--local-stage`** — copies each file to a local temp directory (`/tmp/neutraliser_staging/`) before processing, then copies the result back. Designed to avoid slow random I/O over SMB/NFS. Benchmarks showed **no improvement on fast LAN** (~110 MB/s SMB) where CPU is the bottleneck, but may help on slower network mounts. Cache sidecar files are still read/written next to the original video, not the staged copy.

Both flags are independent and can be combined.

### Key Components

| Component | File | Responsibility |
|---|---|---|
| CLI | `lib/neutraliser/cli.rb` | Thor-based command interface |
| Processor | `lib/neutraliser/processor.rb` | Pipeline orchestration, resume (serial dispatch) |
| FFmpegWrapper | `lib/neutraliser/ffmpeg_wrapper.rb` | ffmpeg/ffprobe commands, codec selection, loudnorm filter |
| ObjectAudio | `lib/neutraliser/object_audio.rb` | Atmos / DTS:X detection (stream profile, name-hinted mid-file probe) |
| AudioAnalyser | `lib/neutraliser/audio_analyser.rb` | Loudness analysis with sidecar caching |
| CacheManager | `lib/neutraliser/cache_manager.rb` | Sidecar `.loudnorm_{profile}.json` analysis cache read/write |
| SkipDecider | `lib/neutraliser/skip_decider.rb` | Single authority for "already normalised?" — the in-file Stamp for the same profile, cached in one `.neutraliser` sidecar (size+mtime+profile, never expires), quick LUFS sampling as an internal fallback strategy |
| Stamp | `lib/neutraliser/stamp.rb` | Value object for the `NEUTRALISER_*` tags: what was done to a file, both directions of the tag encoding |
| GainPlan | `lib/neutraliser/gain_plan.rb` | The constant-gain decision for a measurement: applied gain capped by the true-peak headroom (plus `--limit-db`), limiter filter, shortfall, direction-aware `worthwhile?` |
| DiskGuard / RunLock | `lib/neutraliser/disk_guard.rb`, `run_lock.rb` | Free-space floors (skip a file / abort the run) and the flock run lock, for unattended NAS sweeps |
| ManifestImport | `lib/neutraliser/manifest_import.rb` | Carries the retired `neutralise.sh` manifest into `.neutraliser` sidecars |
| Report | `lib/neutraliser/report.rb` | `neutraliser report`: reads stamps and left-alone records across a directory, counts, per-file rows and the remote-free rate |
| Recipe | `lib/neutraliser/recipe.rb` | The leveling method's version number; what `--redo-recipe` accepts |
| LeftRecord | `lib/neutraliser/left_record.rb` | Why a file was left as it is, with measured levels; stored in the sidecar |
| RemoteFreeRate | `lib/neutraliser/remote_free_rate.rb` | `FinalLevels` (computed or measured) and the share of files within 2 LU of target and under an LRA limit |
| RateHarness | `lib/neutraliser/rate_harness.rb` | `neutraliser rate-sample`: a recipe tried on copies of a random sample across roots |
| FileManager | `lib/neutraliser/file_manager.rb` | Atomic file replacement, integrity verification |
| LocalStager | `lib/neutraliser/local_stager.rb` | Stage files to local NVMe for fast processing, copy result back |

## Decisions / Rationale

- **Two-pass loudnorm** — first pass measures, second pass applies with measured values for accurate normalisation.
- **Smart codec selection** — match source codec and bitrate to avoid quality loss. See [ADR-0001](adr/0001-smart-codec-selection.md).
- **Sidecar caching** — `.loudnorm_{profile}.json` files next to videos avoid re-analysis on repeated runs.
- **The file is the record** — the `.neutraliser` sidecar lives in whichever root a run started from, so moving a file or running from another root lost the record and could cause another lossy re-encode. The Stamp travels with the file. The sidecar stays as a cache in front of the one-ffprobe tag check and is refreshed on a tag hit.
- **One skip decider** — SkipDecider is the single place that answers "is this file already normalised?", backed by one sidecar (`.neutraliser`) and one staleness rule (size+mtime+profile, never expires). Quick LUFS sampling lives inside it as an internal fallback strategy and never writes its own marker file; a verified quick sample is recorded through the same sidecar. The legacy `.{basename}.neutralised_{profile}` marker format is retired; `neutraliser cache clean` removes any left over from older runs.
- **Atomic replace** — write to a hidden temp file, verify it against the source (duration, streams, chapters, primary channels), check the source has not changed, then rename. Copy mode does the same onto `_normalized`.

## Next Actions

- [ ] Add container/codec compatibility diagram.
- [ ] Document Plex integration flow.

## References / Links

- docs/design/adr/
- docs/ops/runbook.md

### Change Log
- 2026-10-20 (agent:prod-parity): Added GainPlan, DiskGuard/RunLock and ManifestImport components

- 2026-10-15 (agent:record-what-was-done): Added the Stamp section (in-file NEUTRALISER_* tags), Stamp and Report components, tag-first skip decision
- 2026-10-15 (agent:object-audio): Added object-audio skip section, ObjectAudio component, profile in probe
- 2025-09-24 (agent:create-project): Created architecture placeholder
- 2026-03-07 (agent:implement-plan): Added pipeline diagram, codec selection, component table
- 2026-03-08 (agent:implement-plan): Added performance flags section, LocalStager component
- 2026-08-06 (agent:improve-architecture): Removed stale ParallelProcessor row, added ProcessedTracker
- 2026-08-07 (agent:consolidate-already-normalised-decision): Replaced ProcessedTracker + FastVerifier with a single SkipDecider (one sidecar, one staleness rule); quick-sample tolerance margin is now an explicit documented constant instead of a hidden `tolerance * 0.8`
