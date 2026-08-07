---
type: architecture
status: draft
owner: will
contributors: []
updated: 2026-03-07
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
│  │ SkipDecider   │  │  Single "already normalised?" authority (sidecar
│  └───────┬───────┘  │  hit, or quick LUFS sample as a fallback strategy)
│          ▼          │
│  ┌───────────────┐  │
│  │ AudioAnalyser │  │  Full loudnorm measurement (with sidecar cache)
│  └───────┬───────┘  │
│          ▼          │
│  ┌───────────────┐  │
│  │ FFmpegWrapper │  │  Two-pass loudnorm: measure → apply
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

1. **Probe** — `detect_audio_tracks` reads codec, bitrate, sample rate, and channel count via ffprobe.
2. **Match** — `select_output_codec` tries to re-encode to the same codec at `max(source_bitrate, quality_floor)`, capped at a per-codec maximum.
3. **Fallback** — non-encodable codecs (DTS, TrueHD) fall back to FLAC in MKV or EAC3/AC3 in MP4. Lossless sources stay lossless when the container supports it.
4. **Log** — every normalisation logs the decision (e.g., `Audio: ac3 448k -> ac3 448k`).

See [ADR-0001](adr/0001-smart-codec-selection.md) for the full rationale.

### Performance Flags

Two optional flags reduce per-file processing time. See [ADR-0002](adr/0002-performance-flags.md) for rationale and benchmark data.

- **`--fast`** — uses FFmpeg's single-pass loudnorm (dynamic mode) instead of the default two-pass (linear mode). Skips the measurement pass entirely. Benchmarked at **30-37% faster**. Slightly less accurate — uses dynamic gain adjustment rather than a constant linear offset.
- **`--local-stage`** — copies each file to a local temp directory (`/tmp/neutraliser_staging/`) before processing, then copies the result back. Designed to avoid slow random I/O over SMB/NFS. Benchmarks showed **no improvement on fast LAN** (~110 MB/s SMB) where CPU is the bottleneck, but may help on slower network mounts. Cache sidecar files are still read/written next to the original video, not the staged copy.

Both flags are independent and can be combined.

### Key Components

| Component | File | Responsibility |
|---|---|---|
| CLI | `lib/neutraliser/cli.rb` | Thor-based command interface |
| Processor | `lib/neutraliser/processor.rb` | Pipeline orchestration, resume (serial dispatch) |
| FFmpegWrapper | `lib/neutraliser/ffmpeg_wrapper.rb` | ffmpeg/ffprobe commands, codec selection, loudnorm filter |
| AudioAnalyser | `lib/neutraliser/audio_analyser.rb` | Loudness analysis with sidecar caching |
| CacheManager | `lib/neutraliser/cache_manager.rb` | Sidecar `.loudnorm_{profile}.json` analysis cache read/write |
| SkipDecider | `lib/neutraliser/skip_decider.rb` | Single authority for "already normalised?" — one `.neutraliser` sidecar (size+mtime+profile, never expires), quick LUFS sampling as an internal fallback strategy |
| FileManager | `lib/neutraliser/file_manager.rb` | Atomic file replacement, integrity verification |
| LocalStager | `lib/neutraliser/local_stager.rb` | Stage files to local NVMe for fast processing, copy result back |

## Decisions / Rationale

- **Two-pass loudnorm** — first pass measures, second pass applies with measured values for accurate normalisation.
- **Smart codec selection** — match source codec and bitrate to avoid quality loss. See [ADR-0001](adr/0001-smart-codec-selection.md).
- **Sidecar caching** — `.loudnorm_{profile}.json` files next to videos avoid re-analysis on repeated runs.
- **One skip decider** — SkipDecider is the single place that answers "is this file already normalised?", backed by one sidecar (`.neutraliser`) and one staleness rule (size+mtime+profile, never expires). Quick LUFS sampling lives inside it as an internal fallback strategy and never writes its own marker file; a verified quick sample is recorded through the same sidecar. The legacy `.{basename}.neutralised_{profile}` marker format is retired; `neutraliser cache clean` removes any left over from older runs.
- **Atomic replace** — write to temp file, verify integrity, then rename to prevent corruption.

## Next Actions

- [ ] Add container/codec compatibility diagram.
- [ ] Document Plex integration flow.

## References / Links

- docs/design/adr/
- docs/ops/runbook.md

### Change Log
- 2025-09-24 (agent:create-project): Created architecture placeholder
- 2026-03-07 (agent:implement-plan): Added pipeline diagram, codec selection, component table
- 2026-03-08 (agent:implement-plan): Added performance flags section, LocalStager component
- 2026-08-06 (agent:improve-architecture): Removed stale ParallelProcessor row, added ProcessedTracker
- 2026-08-07 (agent:consolidate-already-normalised-decision): Replaced ProcessedTracker + FastVerifier with a single SkipDecider (one sidecar, one staleness rule); quick-sample tolerance margin is now an explicit documented constant instead of a hidden `tolerance * 0.8`
