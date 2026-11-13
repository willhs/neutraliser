---
type: adr
status: accepted
owner: will
contributors: []
updated: 2026-11-13
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

1. **Direct match** — if the source codec is encodable by ffmpeg and compatible with the output container, re-encode to the same codec at the first-generation bitrate plus headroom, held between the per-codec floor and cap (see *Bitrate headroom* below).
2. **Lossless preservation** — if the source is lossless (FLAC, PCM, TrueHD) and the container supports it (MKV), output FLAC.
3. **Surround fallback** — for non-encodable surround codecs (DTS, TrueHD), prefer FLAC in MKV, EAC3/AC3 in MP4.
4. **Container default** — fall back to the container's preferred codec (e.g., AAC for MP4, FLAC for MKV).

Quality floors and caps are defined per encoder and channel count to prevent encoding below minimum quality or wasting bits above useful thresholds.

## Bitrate headroom (amended 2026-11-13)

The re-encode is one more lossy generation, and matching the source bitrate exactly leaves it that much worse. [Research 0004](../../research/0004-lossy-encoders-libfdk-aac-eac3/research.md) measured native `aac`, `ac3` and `eac3` at +25% over the bitrate we picked: higher in all 16 source-window pairs (ViSQOL +0.05 to +0.06 on average). So the same codec is written at **1.25x the first-generation bitrate**, then clamped to the floor and cap. This departs from "match the source bitrate" on purpose: more bits, same codec.

- **Which encoders.** `aac`, `ac3`, `eac3`, the ones measured (`CodecChoice::HEADROOM`). mp3, Opus, Vorbis and MP2 keep the old rule.
- **First generation.** The bitrate of the earliest source, not of the file in hand: the `NEUTRALISER_SOURCE_BITRATE` of an earlier stamp when it was a pass over this same codec, else the file's own. A second pass (another profile, a `--redo-recipe`) writes the same rate instead of growing 25% each time, and the new stamp keeps the first-generation figure. A stamp for another codec (after a DTS to E-AC-3 change) is ignored.
- **AC-3 steps.** The encoder takes only fixed rates (`CodecChoice::AC3_BITRATES`), so the headroomed rate rounds up to the next one: 448k becomes 576k (560k is not a step), 384k becomes 512k, 192k becomes 256k.
- **Not applied.** To lossless output (no bitrate), to a track whose bitrate is unknown (it stays at the floor), and to a codec change (DTS to E-AC-3/FLAC keeps the old rule). The floors and caps are unchanged, so headroom never takes a stereo AAC over 320k.
- **Cost.** About +25% of the audio track: stereo AAC 128k to 160k is ~14 MB/hour, 5.1 AAC 384k to 480k ~43 MB/hour, AC-3 448k to 576k ~58 MB/hour, E-AC-3 640k to 800k ~72 MB/hour. Small against the video track.
- **Recipe.** `Recipe::CURRENT` is not bumped: files made before this stay as they are and are not offered for a redo. The stamp records the first-generation bitrate only; the rate written is the file's own stream bitrate.

# Consequences (Positive/Negative)

**Positive:**
- No unnecessary quality loss — source quality is preserved as closely as possible
- Lossless sources stay lossless in MKV containers
- Every normalization logs the codec decision for transparency
- Eliminates generational degradation from repeated processing with matching codecs

**Negative:**
- More complex codec selection logic to maintain
- Output file sizes may increase (matching higher source bitrates rather than fixed 256k/640k, and +25% headroom on AAC/AC-3/E-AC-3)
- Container compatibility constraints add edge cases

# Alternatives Considered

- **Always use the highest quality lossy codec** (e.g., AAC 320k / AC3 640k for everything) — simpler but still loses quality for lossless or high-bitrate sources.
- **Always output lossless** (FLAC everywhere) — maximizes quality but FLAC isn't compatible with MP4 containers, and file sizes increase significantly.
- **VBR encoding** — could be more efficient, but CBR matching the source bitrate is simpler and more predictable with the loudnorm filter.
- **Runtime detection of libfdk_aac** — better AAC encoder, but adds complexity. Rejected 2026-11-08: it is not in the Debian ffmpeg the published image uses, the gain at equal bitrate is small and mixed (it cuts the top octave), and output would vary by host. Measurements: [research 0004](../../research/0004-lossy-encoders-libfdk-aac-eac3/research.md). Bitrate headroom on the native encoders helped in every case measured and is now part of this ADR (above).

# Links

- Task spec: `docs/tasks/0004-preserve-audio-quality/task.md`
- Implementation: `lib/neutraliser/codec_choice.rb` (`CodecChoice.decide`) and `lib/neutraliser/codec_tables.rb` (the tables); the codec-change guard and the encode both read `CodecChoice.decide`

### Change Log
- 2026-03-07 (agent:implement-plan): created
- 2026-10-20 (agent:prod-parity): Steps 2-3 (lossless preservation, surround fallback) now run only under `--allow-codec-change`; by default a primary track whose codec can't be re-encoded to itself is skipped (`codec_change`), matching production's `skip_codec` and the vision's "keeps the source codec". See docs/research/prod-parity-audit-2026-10.md.
- 2026-11-08 (agent:research): libfdk_aac alternative marked rejected, with the measurements in research 0004. Decision unchanged.
- 2026-11-13 (agent:implement): bitrate headroom: AAC, AC-3 and E-AC-3 are re-encoded at 1.25x the first-generation bitrate (floors, caps and AC-3 steps still apply), not at the source bitrate. Not for codec changes or lossless. Recipe not bumped.
