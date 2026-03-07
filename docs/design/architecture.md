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
│  │ Fast Verifier │  │  Quick LUFS check — skip if already at target
│  └───────┬───────┘  │
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

### Key Components

| Component | File | Responsibility |
|---|---|---|
| CLI | `lib/neutraliser/cli.rb` | Thor-based command interface |
| Processor | `lib/neutraliser/processor.rb` | Pipeline orchestration, resume, parallel dispatch |
| FFmpegWrapper | `lib/neutraliser/ffmpeg_wrapper.rb` | ffmpeg/ffprobe commands, codec selection, loudnorm filter |
| AudioAnalyser | `lib/neutraliser/audio_analyser.rb` | Loudness analysis with sidecar caching |
| CacheManager | `lib/neutraliser/cache_manager.rb` | Sidecar `.loudnorm.json` cache read/write |
| FastVerifier | `lib/neutraliser/fast_verifier.rb` | Quick LUFS sampling to skip already-normalised files |
| FileManager | `lib/neutraliser/file_manager.rb` | Atomic file replacement, integrity verification |
| ParallelProcessor | `lib/neutraliser/parallel_processor.rb` | Thread-pool dispatch for multi-file runs |

## Decisions / Rationale

- **Two-pass loudnorm** — first pass measures, second pass applies with measured values for accurate normalisation.
- **Smart codec selection** — match source codec and bitrate to avoid quality loss. See [ADR-0001](adr/0001-smart-codec-selection.md).
- **Sidecar caching** — `.loudnorm.json` files next to videos avoid re-analysis on repeated runs.
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
