---
title: "Video Volume Normalisation (\"Neutralisation\") Implementation"
created: 2025-09-26
status: planning
---

# Task: Implement Video Volume Normalisation

## Goal
Implement the core functionality to analyse and normalise audio volume in video files while preserving video quality and creating consistent playback levels.

## Context
This is the foundational feature for the Neutraliser CLI tool. The implementation needs to:
- Analyse existing audio volume levels in video files
- Calculate appropriate normalisation adjustments
- Apply volume changes using FFmpeg while preserving video streams
- Maintain high video quality through stream copying

## Requirements

### Functional Requirements
- Accept video file input (common formats: MP4, MKV, AVI, MOV)
- Analyse current audio volume levels and peak/RMS values
- Calculate normalisation target (e.g., -23 LUFS for broadcast standard)
- Apply volume adjustment to audio track only
- Copy video stream without re-encoding to preserve quality
- Output normalised video file
- Provide progress feedback during processing

### Technical Requirements
- Use FFmpeg for audio analysis and processing
- Implement proper error handling for unsupported formats
- Handle files with multiple audio tracks
- Preserve metadata and subtitles where possible
- Support both creating new files and optional in-place replacement

### Non-Functional Requirements
- Process files efficiently without unnecessary re-encoding
- Handle large video files (>1GB) without memory issues
- Provide clear error messages for common failure scenarios
- Support batch processing preparation (single file implementation first)

## Potential Solutions

### Approach 1: Two-Pass FFmpeg Processing
1. First pass: Analyse audio levels using `ffmpeg -af volumedetect`
2. Calculate required volume adjustment
3. Second pass: Apply volume filter and copy video stream

**Pros:** Simple, reliable, uses standard FFmpeg features
**Cons:** Requires two full file reads for large files

### Approach 2: FFmpeg Loudness Normalization
1. Use FFmpeg's `loudnorm` filter for EBU R128 standard compliance
2. Single pass with audio normalization and video stream copy

**Pros:** Industry-standard normalization, single pass possible
**Cons:** More complex filter setup, may need two-pass for optimal results

### Approach 3: External Audio Analysis + FFmpeg Processing
1. Use Ruby gem for audio analysis (e.g., ruby-audio)
2. Calculate adjustments in Ruby
3. Apply with FFmpeg

**Pros:** More control over analysis logic
**Cons:** Additional dependencies, potentially slower

## Recommended Approach
Start with **Approach 2** using FFmpeg's `loudnorm` filter as it provides industry-standard EBU R128 normalization. Use **two-pass loudnorm** processing for optimal results where every file lands at the same Integrated LUFS target.

### Normalization Targets
Choose one profile and stick to it:

- **Reference / Home Theater (best fidelity)**
  `I = -23 LUFS`, `TP = -1.5 dBTP`, keep content's natural LRA (don't clamp unless extreme).
  Matches broadcast/EBU R128/ATSC and plays nicely with 5.1/7.1 mixes.

- **Living-room / Soundbar (slightly hotter, still tasteful)**
  `I = -20 LUFS`, `TP = -1.5 dBTP`, optionally cap `LRA` around `12`.

- **Laptop / Night mode (least remote-grabbing)**
  `I = -16 LUFS`, `TP = -1.5 dBTP`, cap `LRA` around `10–12` (or even `8`).
  "Podcast-ish" loud; dynamic-range reduced but super consistent.

**Recommendation:** Use **-20 LUFS** for general living-room setups. If you have an AVR and headroom, use **-23 LUFS**.

### Two-Pass FFmpeg Implementation

#### 1) Measurement Pass (audio analysis only)
```bash
ffmpeg -hide_banner -nostats -i "INPUT" \
  -map a:0 \
  -af loudnorm=I=-20:TP=-1.5:LRA=12:print_format=json \
  -f null - 2>&1
```
Parse the JSON output containing: `input_i`, `input_tp`, `input_lra`, `input_thresh`, `offset`, `linear_gain`.

#### 2) Apply Pass (actual normalization)
```bash
ffmpeg -hide_banner -i "INPUT" \
  -map 0:v -c:v copy \
  -map 0:a:0 -af loudnorm=I=-20:TP=-1.5:LRA=12:measured_I=INPUT_I:measured_TP=INPUT_TP:measured_LRA=INPUT_LRA:measured_thresh=INPUT_THRESH:offset=OFFSET:linear=true:print_format=summary \
  -map_chapters 0 -map_metadata 0 \
  -c:a ac3 -b:a 640k \
  "OUTPUT.mkv"
```

**Notes:**
- `-c:v copy` avoids touching video
- For **5.1**, AC-3 640k is widely compatible. For **stereo**, AAC 192–256k is fine
- `TP=-1.5` keeps intersample peaks from clipping DACs
- Don't rely on AC-3 **dialnorm** metadata—actually normalize samples

## Success Criteria
- [ ] Successfully normalise audio in test video file
- [ ] Video quality remains unchanged (stream copied)
- [ ] Audio levels meet target normalization standard
- [ ] Process completes with appropriate progress feedback
- [ ] Error handling works for invalid input files
- [ ] Metadata and subtitles preserved in output

## Implementation Details

### Ruby CLI Architecture
Don't need an audio library in Ruby—shell out, parse, and track state.

```ruby
require "json"
require "open3"
require "fileutils"
require "shellwords"

TARGET_I   = -20.0   # pick -23, -20, or -16
TARGET_TP  = -1.5
TARGET_LRA = 12.0    # relax for Reference profile if desired

def ffmpeg_measure(input)
  cmd = [
    "ffmpeg", "-hide_banner", "-nostats", "-i", input,
    "-map", "a:0",
    "-af", "loudnorm=I=#{TARGET_I}:TP=#{TARGET_TP}:LRA=#{TARGET_LRA}:print_format=json",
    "-f", "null", "-"
  ]
  stdout, stderr, st = Open3.capture3(*cmd)
  raise "ffmpeg failed: #{st.exitstatus}" unless st.success?

  # The JSON is in stderr. Extract the block between { ... }.
  json_text = stderr[/\{\s*"input_i".*?\}/m]
  raise "loudnorm JSON not found" unless json_text

  JSON.parse(json_text)
end

def audio_channels(input)
  stdout, _ = Open3.capture2("ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 #{Shellwords.escape(input)}")
  stdout.to_i
end

def ffmpeg_apply(input, output, measured)
  lf = "loudnorm=I=#{TARGET_I}:TP=#{TARGET_TP}:LRA=#{TARGET_LRA}" \
       ":measured_I=#{measured['input_i']}" \
       ":measured_TP=#{measured['input_tp']}" \
       ":measured_LRA=#{measured['input_lra']}" \
       ":measured_thresh=#{measured['input_thresh']}" \
       ":offset=#{measured['target_offset']}" \
       ":linear=true:print_format=summary"

  # choose audio codec based on channel layout
  channels = audio_channels(input)
  acodec   = channels >= 6 ? ["-c:a", "ac3", "-b:a", "640k"] : ["-c:a", "aac", "-b:a", "256k"]

  cmd = ["ffmpeg", "-hide_banner", "-y", "-i", input,
         "-map", "0:v", "-c:v", "copy",
         "-map", "0:a:0", "-af", lf,
         "-map_chapters", "0", "-map_metadata", "0",
         "-map", "0:s?", "-c:s", "copy"] + acodec + [output]

  system(*cmd) || raise("ffmpeg apply failed")
end

def needs_normalization?(measured, tol_lu: 1.0)
  (measured["input_i"].to_f - TARGET_I).abs > tol_lu
end
```

### End-to-End Workflow

1) **Find media paths**
   - Walk library folders for video files
   - Optional: Use Plex API with `PLEX_URL` + `PLEX_TOKEN` for more sophisticated selection

2) **Measure** with first pass and cache results in sidecar JSON (e.g., `movie.mkv.loudnorm.json`)

3) **Decision**: only normalize files outside tolerance (e.g., ±1 LU) to save processing time

4) **Apply** with two-pass `loudnorm`, writing to temp file, then **atomically swap**:
   - `original.mkv` → `original.mkv.bak` (or keep as track 2)
   - `normalized.mkv` → `original.mkv`

5) **Safety & metadata**
   - Preserve chapters/metadata (`-map_chapters 0 -map_metadata 0`)
   - Preserve subtitle streams (`-map 0:s? -c:s copy`)
   - Handle multiple audio streams: process default, copy others untouched

### Processing Multiple Audio Streams
```bash
ffmpeg -i "INPUT" \
  -map 0:v -c:v copy \
  -map 0:a:0 -af "loudnorm=...measured..." -c:a ac3 -b:a 640k \
  -map 0:a:1? -c:a:1 copy \
  -map 0:s? -c:s copy \
  -map_chapters 0 -map_metadata 0 \
  "OUTPUT.mkv"
```

### Practical Defaults
- **Target**: **-20 LUFS**, **TP -1.5 dBTP**, **LRA 12** (sweet spot for most setups)
- Only re-encode if |measured_I - target| > **1.0 LU**
- Use **MKV** containers (fewest surprises)
- Multichannel sources: **AC-3 640k**. Stereo: **AAC 256k**
- Never touch video streams
- Don't rely on ReplayGain/track-gain tags

### Edge Cases & Tips
- **Downmixing**: If downmixing 5.1 → 2.0, do it *before* loudnorm
- **Performance**: CPU-heavy process - parallelize and skip files within tolerance
- **Night mode**: Offer CLI flag for `I=-16, LRA=10` alternate tracks

### CLI UX Design
```
$ neutraliser scan --root /path/to/media            # measure & cache JSON
$ neutraliser apply --profile livingroom            # (-20 LUFS)
$ neutraliser apply --profile night --add-track     # add extra normalized track
$ neutraliser status                                 # show outliers, progress
```

## Files to Create/Modify
- `lib/neutraliser/video_processor.rb` - Core video processing logic
- `lib/neutraliser/audio_analyser.rb` - Audio level analysis and measurement
- `lib/neutraliser/ffmpeg_wrapper.rb` - FFmpeg command execution and parsing
- `lib/neutraliser/normalizer.rb` - Two-pass normalization workflow
- `lib/neutraliser/file_manager.rb` - Atomic file operations and backups
- `spec/` - Test files for video processing components
- Sample test video files for development

## Dependencies
- FFmpeg (external binary requirement)
- Ruby gems: potentially `open3` for subprocess handling
- Test video files with varying audio levels

---

## Change Log
- 2025-09-26: Initial task creation
- 2025-09-26: Merged detailed implementation guide from plex_audio_normalization.md including FFmpeg two-pass workflow, Ruby code examples, and practical defaults
