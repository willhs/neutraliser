---
type: adr
status: accepted
owner: will
contributors: []
updated: 2026-03-07
review_cycle: 90d
agent_write: true
links: ["docs/tasks/0004-preserve-audio-quality/task.md"]
summary: "Match source audio codec and bitrate during normalization instead of hardcoding AAC/AC3"
tags: ["audio", "ffmpeg", "quality"]
---

# Context

The `loudnorm` filter requires decoding and re-encoding audio — stream copy is impossible. Previously, the tool always re-encoded to a fixed codec and bitrate (AAC 256k for stereo, AC3 640k for surround), regardless of the source format. This caused quality loss in several scenarios:

- High-bitrate sources downgraded (e.g., AAC 512k → AAC 256k)
- Codec changes losing format-specific optimizations (e.g., DTS → AC3)
- Lossless sources (FLAC, TrueHD) forced to low-bitrate lossy
- Repeated processing causing generational degradation

# Decision

Probe the source audio codec and bitrate via ffprobe before normalization, then select the output codec using this priority:

1. **Direct match** — if the source codec is encodable by ffmpeg and compatible with the output container, re-encode to the same codec at `max(source_bitrate, quality_floor)`, capped at a per-codec maximum.
2. **Lossless preservation** — if the source is lossless (FLAC, PCM, TrueHD) and the container supports it (MKV), output FLAC.
3. **Surround fallback** — for non-encodable surround codecs (DTS, TrueHD), prefer FLAC in MKV, EAC3/AC3 in MP4.
4. **Container default** — fall back to the container's preferred codec (e.g., AAC for MP4, FLAC for MKV).

Quality floors and caps are defined per encoder and channel count to prevent encoding below minimum quality or wasting bits above useful thresholds.

# Consequences (Positive/Negative)

**Positive:**
- No unnecessary quality loss — source quality is preserved as closely as possible
- Lossless sources stay lossless in MKV containers
- Every normalization logs the codec decision for transparency
- Eliminates generational degradation from repeated processing with matching codecs

**Negative:**
- More complex codec selection logic to maintain
- Output file sizes may increase (matching higher source bitrates rather than fixed 256k/640k)
- Container compatibility constraints add edge cases

# Alternatives Considered

- **Always use the highest quality lossy codec** (e.g., AAC 320k / AC3 640k for everything) — simpler but still loses quality for lossless or high-bitrate sources.
- **Always output lossless** (FLAC everywhere) — maximizes quality but FLAC isn't compatible with MP4 containers, and file sizes increase significantly.
- **VBR encoding** — could be more efficient, but CBR matching the source bitrate is simpler and more predictable with the loudnorm filter.
- **Runtime detection of libfdk_aac** — better AAC encoder, but adds complexity; deferred for future work.

# Links

- Task spec: `docs/tasks/0004-preserve-audio-quality/task.md`
- Implementation: `lib/neutraliser/ffmpeg_wrapper.rb` (constants and `select_output_codec`)

### Change Log
- 2026-03-07 (agent:implement-plan): created
