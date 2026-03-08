---
id: task-0004
type: spec
purpose: "Prevent audio quality loss during normalization by matching source codec and bitrate instead of always re-encoding to fixed AAC/AC3"
tags: ["audio", "ffmpeg", "quality"]
related: ["docs/tasks/0002-video-volume-normalisation/plan.md"]
created: 2026-03-07
updated: 2026-03-07
---

# Preserve Audio Quality During Normalization

## Goal

When rewriting video files with normalized audio, preserve the original audio quality as closely as possible by matching the source codec and bitrate, rather than always re-encoding to AAC 256k (stereo) or AC3 640k (surround).

## Context

The current `FFmpegWrapper.select_audio_codec` method hardcodes the output codec and bitrate:
- Stereo/mono: AAC at 256 kbps
- 5.1+ surround: AC3 at 640 kbps

This causes quality loss in several scenarios:
- Source audio at a higher bitrate than the fixed target (e.g., AAC 512k becomes AAC 256k)
- Source using a different codec entirely (e.g., DTS 1.5 Mbps becomes AC3 640k)
- Lossless sources (FLAC, PCM, TrueHD) downgraded to lossy
- Repeated processing causes generational lossy-to-lossy degradation

The `loudnorm` filter requires decoding and re-encoding (stream copy is impossible), so some re-encoding is unavoidable. The goal is to minimize quality degradation by making smart codec and bitrate choices.

## Requirements

- Detect source audio codec and bitrate before normalization
- When the source codec is encodable by ffmpeg (AAC, AC3, Opus, MP3, Vorbis), re-encode to the same codec at max(source_bitrate, quality_floor)
- When the source codec is not encodable by ffmpeg (DTS, TrueHD), fall back to the best available alternative: FLAC for MKV containers, AC3 640k for MP4
- When the source is lossless (FLAC, PCM, TrueHD), output FLAC for MKV containers or high-bitrate AAC/AC3 for MP4
- Define sensible quality floor bitrates per codec so we never encode below a minimum quality
- Preserve sample rate and channel layout from the source
- Log the codec decision (e.g., "Re-encoding AAC 512k -> AAC 512k" or "DTS 1.5M -> FLAC (lossless)")

## Success Criteria

- [ ] Source codec and bitrate are detected via ffprobe before normalization
- [ ] Output codec matches source codec when ffmpeg can encode it
- [ ] Output bitrate is at least as high as source bitrate (up to a sane cap)
- [ ] Non-encodable codecs (DTS, TrueHD) fall back appropriately per container
- [ ] Lossless sources get lossless output in MKV, high-bitrate lossy in MP4
- [ ] Codec/bitrate decision is logged for transparency
- [ ] Existing tests pass; new tests cover codec selection logic
