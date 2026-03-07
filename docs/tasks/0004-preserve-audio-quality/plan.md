---
id: plan-0004
type: spec
purpose: "Implementation plan for preserving audio quality during normalization by matching source codec and bitrate."
tags: ["plan", "audio", "ffmpeg", "quality"]
related: ["./task.md"]
---

# Preserve Audio Quality Implementation Plan

## Overview

Replace the hardcoded AAC 256k / AC3 640k codec selection with intelligent codec and bitrate matching that probes the source audio and re-encodes to the same codec at the same (or higher) bitrate, with sensible fallbacks for non-encodable codecs and container constraints.

**Primary Goal**: No audio quality degradation compared to source, except the unavoidable decode/re-encode from the loudnorm filter.

**Approach**: Probe source codec + bitrate via ffprobe, look up whether the codec is encodable and compatible with the output container, select the best match, and encode at max(source_bitrate, quality_floor).

## Current State Analysis

- `select_audio_codec` (`ffmpeg_wrapper.rb:136-138`) makes a binary choice based solely on channel count
- `detect_audio_tracks` (`ffmpeg_wrapper.rb:100-123`) already captures codec name but **not** bitrate or sample rate
- The codec name in the track hash is never used for encoding decisions
- Test coverage for codec selection is indirect — only the 6-channel AC3 path is tested

### Key Discoveries
- System has: `aac`, `ac3`, `eac3`, `flac`, `pcm_s16le`, `libopus`, `libvorbis`, `libmp3lame`, `dca` (lossy DTS only)
- System does **not** have: `libfdk_aac` (better AAC encoder)
- TrueHD cannot be encoded by ffmpeg at all
- DTS encoding via `dca` is unreliable and low quality — better to fall back to AC3 or FLAC

## Desired End State

- Source AAC 512k in MP4 -> re-encoded AAC 512k in MP4
- Source AC3 448k in MKV -> re-encoded AC3 448k in MKV
- Source DTS 1.5M in MKV -> FLAC (lossless) in MKV
- Source DTS 768k in MP4 -> AC3 640k in MP4 (best lossy option for container)
- Source FLAC in MKV -> FLAC in MKV
- Source PCM in AVI -> AAC 256k in AVI (PCM not ideal, AAC is practical)
- Every normalization logs: "Audio: ac3 448k -> ac3 448k" or "Audio: dts 1509k -> flac (lossless)"

## What We're NOT Doing

- Detecting/using `libfdk_aac` at runtime (can add later if needed)
- VBR encoding (the loudnorm two-pass already produces consistent output; CBR matching source bitrate is simpler and more predictable)
- Handling video codec changes or container conversion
- Multi-track normalization (still only normalizing primary track, copying others)

---

## Phase 1: Probe Source Audio Properties

### Overview
Extend `detect_audio_tracks` to capture bitrate and sample rate from ffprobe, so downstream code has the information needed to make smart codec choices.

### Tasks

#### 1. Update `detect_audio_tracks` to probe bitrate and sample rate
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — update the ffprobe command in `detect_audio_tracks` to include `bit_rate` and `sample_rate` in the stream entries

Change the ffprobe command from:
```ruby
cmd = [
  "ffprobe", "-v", "error", "-select_streams", "a",
  "-show_entries", "stream=index,channels,codec_name",
  "-of", "csv=p=0", input_path
]
```

To:
```ruby
cmd = [
  "ffprobe", "-v", "error", "-select_streams", "a",
  "-show_entries", "stream=index,channels,codec_name,bit_rate,sample_rate",
  "-of", "csv=p=0", input_path
]
```

Update the parsing block to extract the two new fields:
```ruby
tracks = stdout.strip.split("\n").map.with_index do |line, idx|
  parts = line.split(',')
  {
    index: idx,
    stream_index: parts[0].to_i,
    channels: parts[1].to_i,
    codec: parts[2] || 'unknown',
    bit_rate: parts[3]&.to_i,
    sample_rate: parts[4]&.to_i
  }
end
```

Note: `bit_rate` may be nil/0 for some codecs (e.g., lossless or variable). The `&.to_i` handles nil safely, and the codec selection logic will treat 0/nil as "unknown bitrate."

- [x] Update the fallback default track hash (lines 109 and 122) to include the new fields:
```ruby
[{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }]
```

#### 2. Update tests for `detect_audio_tracks`
- [x] Edit `spec/ffmpeg_wrapper_spec.rb` — update the existing CSV parsing test

Change the test CSV input and expected output to include bitrate and sample rate:
```ruby
it 'parses ffprobe csv output including bitrate and sample rate' do
  ffprobe_csv = "1,6,ac3,640000,48000\n2,2,aac,256000,44100\n"
  allow(Open3).to receive(:capture3).and_return([ffprobe_csv, '', ok_status])

  result = described_class.detect_audio_tracks('test.mp4')

  expect(result).to eq([
    { index: 0, stream_index: 1, channels: 6, codec: 'ac3', bit_rate: 640000, sample_rate: 48000 },
    { index: 1, stream_index: 2, channels: 2, codec: 'aac', bit_rate: 256000, sample_rate: 44100 }
  ])
end
```

- [x] Update the failure fallback test to include new fields:
```ruby
it 'returns a default track when ffprobe fails' do
  allow(Open3).to receive(:capture3).and_return(['', 'err', fail_status])

  result = described_class.detect_audio_tracks('bad.mp4')
  expect(result).to eq([{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }])
end
```

- [x] Add a test for tracks where bitrate is not reported (e.g., lossless):
```ruby
it 'handles missing bitrate fields gracefully' do
  ffprobe_csv = "1,6,flac,N/A,48000\n"
  allow(Open3).to receive(:capture3).and_return([ffprobe_csv, '', ok_status])

  result = described_class.detect_audio_tracks('test.mkv')

  expect(result.first[:bit_rate]).to eq(0)
  expect(result.first[:sample_rate]).to eq(48000)
end
```

#### 3. Update processor test stub
- [x] Edit `spec/processor_spec.rb` line 194 — add new fields to the stubbed track hash:
```ruby
allow(processor).to receive(:detect_audio_tracks).and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256000, sample_rate: 48000 }])
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` — all tests pass
- [x] Run: `bundle exec rspec spec/processor_spec.rb` — all tests pass

---

## Phase 2: Smart Codec Selection

### Overview
Replace the binary `select_audio_codec` with a codec selection system that matches the source codec, respects container constraints, and picks appropriate bitrates.

### Tasks

#### 1. Add codec configuration constants
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — add constants after the class definition (after line 7):

```ruby
# Mapping from source codec to ffmpeg encoder name
# Only codecs that ffmpeg can reliably encode
ENCODABLE_CODECS = {
  'aac' => 'aac',
  'ac3' => 'ac3',
  'eac3' => 'eac3',
  'mp3' => 'libmp3lame',
  'mp2' => 'libtwolame',
  'opus' => 'libopus',
  'vorbis' => 'libvorbis',
  'flac' => 'flac',
  'pcm_s16le' => 'pcm_s16le',
  'pcm_s16be' => 'pcm_s16be',
  'pcm_s24le' => 'pcm_s24le',
  'pcm_f32le' => 'pcm_f32le',
}.freeze

# Codecs considered lossless
LOSSLESS_CODECS = %w[flac pcm_s16le pcm_s16be pcm_s24le pcm_f32le truehd pcm_s32le].freeze

# Minimum quality floor bitrates per encoder (in bps)
# We never encode below these regardless of source bitrate
QUALITY_FLOORS = {
  'aac'         => { 2 => 128_000, 6 => 256_000 },
  'ac3'         => { 2 => 192_000, 6 => 384_000 },
  'eac3'        => { 2 => 128_000, 6 => 256_000 },
  'libmp3lame'  => { 2 => 192_000 },
  'libtwolame'  => { 2 => 192_000 },
  'libopus'     => { 2 => 128_000, 6 => 256_000 },
  'libvorbis'   => { 2 => 128_000, 6 => 256_000 },
}.freeze

# Maximum useful bitrates per encoder (in bps)
QUALITY_CAPS = {
  'aac'         => { 2 => 320_000, 6 => 512_000 },
  'ac3'         => { 2 => 640_000, 6 => 640_000 },  # AC3 hard spec max
  'eac3'        => { 2 => 640_000, 6 => 1_536_000 },
  'libmp3lame'  => { 2 => 320_000 },
  'libtwolame'  => { 2 => 384_000 },
  'libopus'     => { 2 => 256_000, 6 => 510_000 },
  'libvorbis'   => { 2 => 256_000, 6 => 500_000 },
}.freeze

# Container compatibility — which encoders work in which containers
CONTAINER_CODECS = {
  '.mp4' => %w[aac ac3 eac3 libmp3lame libopus],
  '.m4v' => %w[aac ac3 eac3 libmp3lame libopus],
  '.mov' => %w[aac ac3 eac3 libmp3lame pcm_s16le pcm_s24le],
  '.mkv' => %w[aac ac3 eac3 libmp3lame libtwolame libopus libvorbis flac pcm_s16le pcm_s24le pcm_f32le],
  '.webm' => %w[libopus libvorbis],
  '.avi' => %w[aac ac3 libmp3lame pcm_s16le],
  '.wmv' => %w[aac ac3 libmp3lame],
  '.flv' => %w[aac libmp3lame],
}.freeze

# Preferred fallback codec per container when source codec can't be matched
CONTAINER_FALLBACKS = {
  '.mkv' => 'flac',
  '.mp4' => 'aac',
  '.m4v' => 'aac',
  '.mov' => 'aac',
  '.webm' => 'libopus',
  '.avi' => 'aac',
  '.wmv' => 'aac',
  '.flv' => 'aac',
}.freeze
```

#### 2. Add the new `select_output_codec` method
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — add a new private class method below `select_audio_codec`:

```ruby
def self.select_output_codec(track, output_path)
  source_codec = track[:codec]&.downcase || 'unknown'
  channels = track[:channels].to_i
  channels = 2 if channels == 0
  source_bitrate = track[:bit_rate].to_i
  container = File.extname(output_path).downcase

  allowed = CONTAINER_CODECS.fetch(container, CONTAINER_CODECS['.mkv'])

  encoder = resolve_encoder(source_codec, allowed, container, channels)
  bitrate = resolve_bitrate(encoder, source_bitrate, channels)

  {
    encoder: encoder,
    bitrate: bitrate,
    source_codec: source_codec,
    source_bitrate: source_bitrate,
    lossless_output: lossless_encoder?(encoder)
  }
end

def self.resolve_encoder(source_codec, allowed, container, channels)
  # 1. Try direct match — same codec if encodable and allowed in container
  direct = ENCODABLE_CODECS[source_codec]
  return direct if direct && allowed.include?(direct)

  # 2. Lossless source — prefer lossless output if container supports it
  if LOSSLESS_CODECS.include?(source_codec)
    return 'flac' if allowed.include?('flac')
    return 'pcm_s24le' if allowed.include?('pcm_s24le')
    return 'pcm_s16le' if allowed.include?('pcm_s16le')
  end

  # 3. Surround non-encodable codecs (DTS, TrueHD) — prefer AC3/EAC3
  if channels >= 6
    return 'eac3' if allowed.include?('eac3')
    return 'ac3' if allowed.include?('ac3')
  end

  # 4. Container default fallback
  fallback = CONTAINER_FALLBACKS.fetch(container, 'aac')
  return fallback if allowed.include?(fallback)

  # 5. Last resort — first allowed codec
  allowed.first || 'aac'
end

def self.resolve_bitrate(encoder, source_bitrate, channels)
  return nil if lossless_encoder?(encoder)

  channel_key = channels >= 6 ? 6 : 2
  floor = QUALITY_FLOORS.dig(encoder, channel_key) || QUALITY_FLOORS.dig(encoder, 2) || 128_000
  cap = QUALITY_CAPS.dig(encoder, channel_key) || QUALITY_CAPS.dig(encoder, 2) || 640_000

  if source_bitrate > 0
    [[source_bitrate, floor].max, cap].min
  else
    floor
  end
end

def self.lossless_encoder?(encoder)
  encoder.start_with?('flac', 'pcm_')
end
```

#### 3. Add tests for codec selection
- [x] Edit `spec/ffmpeg_wrapper_spec.rb` — add a new describe block for `select_output_codec`:

```ruby
describe '.select_output_codec' do
  def make_track(codec:, channels: 2, bit_rate: 256_000, sample_rate: 48_000)
    { index: 0, stream_index: 0, channels: channels, codec: codec, bit_rate: bit_rate, sample_rate: sample_rate }
  end

  it 'matches source AAC codec and bitrate for MP4' do
    result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 512_000), 'out.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(512_000)
  end

  it 'matches source AC3 for MKV' do
    result = described_class.send(:select_output_codec, make_track(codec: 'ac3', channels: 6, bit_rate: 448_000), 'out.mkv')
    expect(result[:encoder]).to eq('ac3')
    expect(result[:bitrate]).to eq(448_000)
  end

  it 'enforces quality floor when source bitrate is low' do
    result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 64_000), 'out.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'caps bitrate at codec maximum' do
    result = described_class.send(:select_output_codec, make_track(codec: 'ac3', channels: 6, bit_rate: 900_000), 'out.mp4')
    expect(result[:bitrate]).to eq(640_000)
  end

  it 'falls back to FLAC for DTS source in MKV' do
    result = described_class.send(:select_output_codec, make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), 'out.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
    expect(result[:bitrate]).to be_nil
  end

  it 'falls back to EAC3 for DTS source in MP4' do
    result = described_class.send(:select_output_codec, make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), 'out.mp4')
    expect(result[:encoder]).to eq('eac3')
  end

  it 'falls back to FLAC for TrueHD source in MKV' do
    result = described_class.send(:select_output_codec, make_track(codec: 'truehd', channels: 6, bit_rate: 0), 'out.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
  end

  it 'preserves FLAC for lossless source in MKV' do
    result = described_class.send(:select_output_codec, make_track(codec: 'flac', channels: 2, bit_rate: 0), 'out.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
  end

  it 'falls back to high-bitrate AAC for FLAC source in MP4' do
    result = described_class.send(:select_output_codec, make_track(codec: 'flac', channels: 2, bit_rate: 0), 'out.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'uses libopus for Opus source in WebM' do
    result = described_class.send(:select_output_codec, make_track(codec: 'opus', bit_rate: 128_000), 'out.webm')
    expect(result[:encoder]).to eq('libopus')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'uses libmp3lame for MP3 source in MP4' do
    result = described_class.send(:select_output_codec, make_track(codec: 'mp3', bit_rate: 320_000), 'out.mp4')
    expect(result[:encoder]).to eq('libmp3lame')
    expect(result[:bitrate]).to eq(320_000)
  end

  it 'handles unknown source codec with container fallback' do
    result = described_class.send(:select_output_codec, make_track(codec: 'unknown', bit_rate: 0), 'out.mp4')
    expect(result[:encoder]).to eq('aac')
  end

  it 'uses quality floor when source bitrate is unknown' do
    result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 0), 'out.mp4')
    expect(result[:bitrate]).to eq(128_000)
  end
end
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` — all tests pass including new codec selection tests

---

## Phase 3: Wire Up and Log Decisions

### Overview
Replace the old `select_audio_codec` call site with the new `select_output_codec`, update the command builder, and add logging.

### Tasks

#### 1. Update `apply_normalization` to use new codec selection
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — replace the `apply_normalization` method (lines 62-75):

```ruby
def self.apply_normalization(input_path, output_path, measured_data, target_i: -20.0, target_tp: -1.5, target_lra: 12.0, audio_tracks: nil)
  audio_tracks ||= detect_audio_tracks(input_path)
  primary_track = audio_tracks.first || { index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }

  codec_decision = select_output_codec(primary_track, output_path)
  codec_args = build_codec_args(codec_decision)

  loudnorm_filter = build_loudnorm_filter(measured_data, target_i, target_tp, target_lra)

  cmd = build_complete_ffmpeg_command(
    input_path, output_path, loudnorm_filter,
    codec_args, audio_tracks
  )

  execute_with_progress(cmd)

  codec_decision
end
```

#### 2. Add `build_codec_args` helper
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — add a new private method:

```ruby
def self.build_codec_args(codec_decision)
  args = ["-c:a:0", codec_decision[:encoder]]
  if codec_decision[:bitrate]
    args += ["-b:a:0", "#{codec_decision[:bitrate] / 1000}k"]
  end
  args
end
```

#### 3. Update `apply_normalization_with_multiple_tracks` to return codec decision
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — update the method to return the codec decision:

```ruby
def self.apply_normalization_with_multiple_tracks(input_path, output_path, measured_data, audio_tracks, profile)
  apply_normalization(input_path, output_path, measured_data,
                     target_i: profile[:lufs],
                     target_tp: profile[:tp],
                     target_lra: profile[:lra],
                     audio_tracks: audio_tracks)
end
```

(This already returns the result of `apply_normalization`, so the change is just to `apply_normalization` itself returning `codec_decision`.)

#### 4. Add codec decision logging to `Processor#normalize_file`
- [x] Edit `lib/neutraliser/processor.rb` — update the `normalize_file` method to capture and log the codec decision. Change the call to `FFmpegWrapper.apply_normalization_with_multiple_tracks` and add a log line after it:

Replace:
```ruby
FFmpegWrapper.apply_normalization_with_multiple_tracks(
  file_path, output_path, measured_data, audio_tracks, @profile
)
```

With:
```ruby
codec_decision = FFmpegWrapper.apply_normalization_with_multiple_tracks(
  file_path, output_path, measured_data, audio_tracks, @profile
)

log_codec_decision(codec_decision)
```

- [x] Add the `log_codec_decision` private method to `Processor`:

```ruby
def log_codec_decision(decision)
  return unless decision.is_a?(Hash) && decision[:encoder]

  source = "#{decision[:source_codec]}"
  source += " #{decision[:source_bitrate] / 1000}k" if decision[:source_bitrate].to_i > 0

  if decision[:lossless_output]
    target = "#{decision[:encoder]} (lossless)"
  else
    target = "#{decision[:encoder]} #{decision[:bitrate].to_i / 1000}k"
  end

  log "  Audio: #{source} -> #{target}"
end
```

#### 5. Remove old `select_audio_codec` method
- [x] Edit `lib/neutraliser/ffmpeg_wrapper.rb` — delete the old `select_audio_codec` method (lines 136-138):

```ruby
def self.select_audio_codec(channel_count)
  channel_count.to_i >= 6 ? ["-c:a:0", "ac3", "-b:a:0", "640k"] : ["-c:a:0", "aac", "-b:a:0", "256k"]
end
```

Also remove `detect_audio_channels` (lines 85-98) since it's no longer needed — the channel count now comes from the track hash.

#### 6. Update existing tests
- [x] Edit `spec/ffmpeg_wrapper_spec.rb` — update the `apply_normalization_with_multiple_tracks` test to verify the new codec selection behavior:

```ruby
it 'uses source-matched codec for primary track and copies additional tracks' do
  tracks = [
    { index: 0, channels: 6, codec: 'ac3', bit_rate: 448_000, sample_rate: 48_000 },
    { index: 1, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
  ]
  allow(Open3).to receive(:capture3).and_return(['', '', ok_status])

  result = described_class.apply_normalization_with_multiple_tracks('in.mkv', 'out.mkv', measured_data, tracks, profile)

  expect(Open3).to have_received(:capture3) do |*args|
    expect(args).to include('-c:a:0', 'ac3', '-b:a:0', '448k')
    expect(args).to include('-map', '0:a:1', '-c:a:1', 'copy')
  end
  expect(result[:encoder]).to eq('ac3')
  expect(result[:bitrate]).to eq(448_000)
end
```

- [x] Remove the `detect_audio_channels` test (lines 99-105) since the method is being removed.

- [x] Update `spec/audio_analyser_spec.rb` — remove or update any test referencing `audio_channels` if it delegates to the removed `detect_audio_channels`.

- [x] Update `spec/processor_spec.rb` — update the `normalize_file` test to expect the codec decision return value:

```ruby
before do
  File.write(video_file, 'x')
  allow(processor).to receive(:detect_audio_tracks).and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
  allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization_with_multiple_tracks).and_return(
    { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false }
  )
  allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
end
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec` — all tests pass
- [x] Run: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` — all codec selection and normalization tests pass
- [x] Run: `bundle exec rspec spec/processor_spec.rb` — processor tests pass with codec logging

#### Manual Verification:
- [x] Manual: Process a video with AAC audio and verify log shows "Audio: aac 256k -> aac 256k" (or similar matched output)
- [x] Manual: If available, process a video with DTS audio in MKV and verify log shows "Audio: dts 1509k -> flac (lossless)"

---

## Final Checklist

- [x] All phases complete
- [x] All tests passing: `bundle exec rspec`
- [x] No references to old `select_audio_codec` or `detect_audio_channels` remain
- [x] Codec decision is logged for every normalization

## References

- Task: `docs/tasks/0004-preserve-audio-quality/task.md`
- FFmpeg encoder availability: `ffmpeg -encoders | grep audio`
- Container codec compatibility research in plan research notes
