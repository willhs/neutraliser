---
id: plan-0005
type: spec
purpose: "Implementation plan for local NVMe staging and single-pass fast mode."
tags: ["plan", "performance", "staging"]
related: ["./task.md", "docs/tasks/0003-performance-optimization/task.md"]
---

# Local NVMe Staging and Single-Pass Fast Mode Implementation Plan

## Overview

Add two independent CLI flags — `--local-stage` and `--fast` — that reduce per-file processing time on NAS setups where media lives on slow network storage. Local staging copies files to fast local disk before processing. Fast mode uses single-pass loudnorm to skip the measurement pass entirely.

**Primary Goal**: Reduce per-file processing time from ~30 minutes to ~8-12 minutes (staging alone) or ~5-8 minutes (staging + fast).

**Approach**: Two small, independent features wired into the existing `Processor` pipeline. No changes to the parallel processing architecture.

## Current State Analysis

### Processing Pipeline (per file)
1. `Processor#process_file` opens the file with `FFMPEG::Movie.new(file_path)` — `processor.rb:237`
2. `analyze_loudness` does a full-file FFmpeg read (measurement pass) — `processor.rb:244`
3. `normalize_file` does another full-file FFmpeg read + write (normalization pass) — `processor.rb:251`
4. All paths stay on the source filesystem — `file_manager.rb:38-44` puts temp files next to originals

### Key Discoveries
- All file I/O is co-located with the source file (`FileManager.safe_temp_path` uses `File.dirname(original_path)`) — `file_manager.rb:39`
- Cache sidecars use `File.dirname(video_path)` for path construction — `cache_manager.rb:14`
- `FFmpegWrapper.measure_loudness` reads full file for measurement — `ffmpeg_wrapper.rb:74-89`
- `FFmpegWrapper.apply_normalization` reads full file again + writes output — `ffmpeg_wrapper.rb:128-145`
- Two-pass loudnorm uses `linear=true` with pre-measured values — `ffmpeg_wrapper.rb:274`

## Desired End State

- `bundle exec neutraliser process --local-stage /mnt/nas/media/movies` copies each file to `/tmp/neutraliser_staging/`, processes locally, copies result back
- `bundle exec neutraliser process --fast /mnt/nas/media/movies` skips measurement pass, applies loudnorm in a single FFmpeg command
- Both flags combine: `--local-stage --fast` for maximum speed
- All existing behaviour unchanged when neither flag is used

### How to Verify:
1. All existing tests pass: `bundle exec rspec`
2. New unit tests pass for `LocalStager` and single-pass FFmpeg wrapper
3. Manual: process a real file with `--local-stage` and verify output matches two-pass result
4. Manual: process a real file with `--fast` and verify reasonable loudness (within ~1 LU of target)

## What We're NOT Doing

- Auto-detecting network mounts (explicit `--local-stage` flag instead)
- Changing the parallel processing architecture
- Pipelining network transfers with processing (prefetch)
- Configurable staging directory (hardcoded default for now)

---

## Phase 1: LocalStager Class

### Overview
New class that manages copying files to/from a local staging directory.

### Tasks

#### 1. Create LocalStager
- [x] Create `lib/neutraliser/local_stager.rb`

```ruby
require 'fileutils'
require 'securerandom'

module Neutraliser
  class LocalStager
    STAGING_DIR = File.join(ENV['TMPDIR'] || '/tmp', 'neutraliser_staging').freeze

    def initialize(staging_dir: STAGING_DIR)
      @staging_dir = staging_dir
      FileUtils.mkdir_p(@staging_dir)
    end

    def stage_in(remote_path)
      ext = File.extname(remote_path)
      basename = File.basename(remote_path, ext)
      local_path = File.join(@staging_dir, "#{basename}_#{SecureRandom.hex(6)}#{ext}")

      Neutraliser.logger.log "  Staging in: #{remote_path} -> #{local_path}"
      FileUtils.cp(remote_path, local_path)
      local_path
    end

    def stage_out(local_path, remote_destination)
      Neutraliser.logger.log "  Staging out: #{local_path} -> #{remote_destination}"
      FileUtils.cp(local_path, remote_destination)
    end

    def cleanup(local_path)
      FileUtils.rm_f(local_path)
    end

    def staging_dir
      @staging_dir
    end
  end
end
```

#### 2. Require LocalStager
- [x] Add `require_relative 'neutraliser/local_stager'` to `lib/neutraliser.rb` after the `file_manager` require

#### 3. Create LocalStager specs
- [x] Create `spec/local_stager_spec.rb`

```ruby
require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::LocalStager do
  let(:staging_dir) { Dir.mktmpdir }
  let(:stager) { described_class.new(staging_dir: staging_dir) }
  let(:source_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(staging_dir) if Dir.exist?(staging_dir)
    FileUtils.remove_entry(source_dir) if Dir.exist?(source_dir)
  end

  describe '#stage_in' do
    it 'copies file to staging directory and returns local path' do
      source = File.join(source_dir, 'movie.mp4')
      File.write(source, 'video content')

      local_path = stager.stage_in(source)

      expect(local_path).to start_with(staging_dir)
      expect(File.exist?(local_path)).to be true
      expect(File.read(local_path)).to eq('video content')
    end

    it 'preserves file extension' do
      source = File.join(source_dir, 'movie.mkv')
      File.write(source, 'x')

      local_path = stager.stage_in(source)

      expect(File.extname(local_path)).to eq('.mkv')
    end

    it 'generates unique paths to avoid collisions' do
      source = File.join(source_dir, 'movie.mp4')
      File.write(source, 'x')

      path_a = stager.stage_in(source)
      path_b = stager.stage_in(source)

      expect(path_a).not_to eq(path_b)
    end
  end

  describe '#stage_out' do
    it 'copies local file to remote destination' do
      local = File.join(staging_dir, 'output.mp4')
      File.write(local, 'processed')
      dest = File.join(source_dir, 'output.mp4')

      stager.stage_out(local, dest)

      expect(File.read(dest)).to eq('processed')
    end
  end

  describe '#cleanup' do
    it 'removes the staged file' do
      local = File.join(staging_dir, 'temp.mp4')
      File.write(local, 'x')

      stager.cleanup(local)

      expect(File.exist?(local)).to be false
    end

    it 'does not raise if file already gone' do
      expect { stager.cleanup('/tmp/nonexistent_file') }.not_to raise_error
    end
  end
end
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec spec/local_stager_spec.rb` — all pass
- [x] Run: `bundle exec rspec` — all existing tests still pass

---

## Phase 2: Single-Pass Loudnorm

### Overview
Add a single-pass FFmpeg command that applies loudnorm without a prior measurement pass. Uses dynamic mode (`linear=false` implicitly since no measured values are provided).

### Tasks

#### 1. Add single-pass method to FFmpegWrapper
- [x] Add `apply_normalization_single_pass` class method to `lib/neutraliser/ffmpeg_wrapper.rb` after the existing `apply_normalization_with_multiple_tracks` method (after line 153)

```ruby
    def self.apply_normalization_single_pass(input_path, output_path, audio_tracks, profile)
      audio_tracks ||= detect_audio_tracks(input_path)
      primary_track = audio_tracks.first || { index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }

      codec_decision = select_output_codec(primary_track, output_path)
      codec_args = build_codec_args(codec_decision)

      loudnorm_filter = "loudnorm=I=#{profile[:lufs]}:TP=#{profile[:tp]}:LRA=#{profile[:lra]}:print_format=summary"

      cmd = build_complete_ffmpeg_command(
        input_path, output_path, loudnorm_filter,
        codec_args, audio_tracks
      )

      execute_with_progress(cmd)

      codec_decision
    end
```

#### 2. Add single-pass FFmpegWrapper specs
- [x] Add tests to `spec/ffmpeg_wrapper_spec.rb` inside the main describe block

```ruby
  describe '.apply_normalization_single_pass' do
    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0, name: 'livingroom' } }

    it 'builds a loudnorm filter without measured values' do
      allow(described_class).to receive(:detect_audio_tracks).and_return(
        [{ index: 0, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 48_000 }]
      )
      allow(described_class).to receive(:execute_with_progress)

      described_class.apply_normalization_single_pass('/in.mp4', '/out.mp4', nil, profile)

      expect(described_class).to have_received(:execute_with_progress) do |cmd|
        filter_arg = cmd[cmd.index('-filter_complex') + 1]
        expect(filter_arg).to include('loudnorm=I=-20.0:TP=-1.5:LRA=12.0')
        expect(filter_arg).not_to include('measured_I')
        expect(filter_arg).not_to include('linear=true')
      end
    end

    it 'returns a codec decision hash' do
      allow(described_class).to receive(:detect_audio_tracks).and_return(
        [{ index: 0, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 48_000 }]
      )
      allow(described_class).to receive(:execute_with_progress)

      result = described_class.apply_normalization_single_pass('/in.mp4', '/out.mp4', nil, profile)

      expect(result).to include(encoder: 'aac', source_codec: 'aac')
    end
  end
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` — all pass
- [x] Run: `bundle exec rspec` — all existing tests still pass

---

## Phase 3: Wire into Processor and CLI

### Overview
Add `--local-stage` and `--fast` CLI options, thread them through `Processor`, and use them in the processing pipeline.

### Tasks

#### 1. Add CLI options
- [x] Add `--fast` and `--local_stage` options to `lib/neutraliser/cli.rb`, after the `--resume` option (after line 64)

```ruby
    option :fast, type: :boolean, default: false, desc: 'Single-pass normalization (faster, slightly less accurate)'
    option :local_stage, type: :boolean, default: false, desc: 'Copy files to local disk before processing'
```

- [x] Pass new options to `Processor.new` in the `process` method — add after line 76 (the `resume` line)

```ruby
        fast: options[:fast],
        local_stage: options[:local_stage]
```

#### 2. Add parameters to Processor#initialize
- [x] Add `fast:` and `local_stage:` keyword arguments to `Processor#initialize` in `lib/neutraliser/processor.rb` (line 11)

Change the method signature from:
```ruby
    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true, dry_run: false, parallel: true, max_threads: nil, fast_verify: true, resume: false)
```
to:
```ruby
    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true, dry_run: false, parallel: true, max_threads: nil, fast_verify: true, resume: false, fast: false, local_stage: false)
```

- [x] Store the new instance variables after line 27 (`@manifest_mutex = Mutex.new`)

```ruby
      @fast = fast
      @local_stage = local_stage
      @stager = LocalStager.new if local_stage
```

#### 3. Update process_file to support local staging and fast mode
- [x] Replace the `process_file` method body in `lib/neutraliser/processor.rb` (lines 228-261)

Replace from `def process_file(file_path)` through the matching `end`:

```ruby
    def process_file(file_path)
      unless video_file?(file_path)
        log "Skipping '#{file_path}' - not a supported video format"
        return file_result(file_path, status: :skipped, reason: :unsupported_format)
      end

      log "Processing: #{file_path}"

      begin
        working_path = file_path
        if @local_stage
          working_path = @stager.stage_in(file_path)
        end

        movie = FFMPEG::Movie.new(working_path)

        unless movie.audio_stream
          log "  No audio track found, skipping"
          @stager&.cleanup(working_path) if @local_stage
          return file_result(file_path, status: :skipped, reason: :no_audio_track)
        end

        if @fast
          result = process_file_fast(file_path, working_path)
        else
          result = process_file_two_pass(file_path, working_path, movie)
        end

        @stager&.cleanup(working_path) if @local_stage
        result
      rescue => e
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  Error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :processing_error, message: e.message)
      end
    end
```

#### 4. Extract two-pass logic into process_file_two_pass
- [x] Add `process_file_two_pass` private method to `lib/neutraliser/processor.rb` (after `process_file`)

```ruby
    def process_file_two_pass(original_path, working_path, movie)
      measured_data = analyze_loudness_for_path(working_path, original_path)

      if needs_processing?(measured_data)
        if @dry_run
          log "  [DRY RUN] Would normalize: #{measured_data['input_i'].to_f.round(1)} LUFS → #{@profile[:lufs]} LUFS"
          file_result(original_path, status: :done, reason: :dry_run)
        else
          normalize_file_with_paths(original_path, working_path, measured_data)
          file_result(original_path, status: :done, reason: :normalized)
        end
      else
        log "  Already at target level, skipping"
        file_result(original_path, status: :skipped, reason: :within_tolerance)
      end
    end
```

#### 5. Add process_file_fast method
- [x] Add `process_file_fast` private method to `lib/neutraliser/processor.rb` (after `process_file_two_pass`)

```ruby
    def process_file_fast(original_path, working_path)
      if @dry_run
        log "  [DRY RUN] Would normalize (fast single-pass) to #{@profile[:lufs]} LUFS"
        return file_result(original_path, status: :done, reason: :dry_run)
      end

      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

      audio_tracks = detect_audio_tracks(working_path)
      if audio_tracks.length > 1
        log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
      end

      log "  Fast mode: single-pass normalization to #{@profile[:lufs]} LUFS"

      codec_decision = FFmpegWrapper.apply_normalization_single_pass(
        working_path, output_path, audio_tracks, @profile
      )

      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise "Output file verification failed - processing aborted"
      end

      commit_output(original_path, working_path, output_path)
      file_result(original_path, status: :done, reason: :normalized)
    rescue => e
      FileUtils.rm_f(output_path) if output_path && File.exist?(output_path)
      raise e
    end
```

#### 6. Add helper methods for staged path handling
- [x] Add `analyze_loudness_for_path`, `normalize_file_with_paths`, and `commit_output` private methods to `lib/neutraliser/processor.rb`

```ruby
    def analyze_loudness_for_path(working_path, original_path)
      analyzer = AudioAnalyser.new(
        cache_enabled: @cache_enabled,
        use_sidecar: @cache_enabled,
        fast_verification: @fast_verify
      )

      # Use original_path for cache lookups, working_path for FFmpeg
      if @fast_verify && !analyzer.should_analyze_file?(original_path, @profile, tolerance: @tolerance)
        log "  Fast verification: file already at target level"
        return create_target_level_data(@profile)
      end

      # Check cache using original path
      if @cache_enabled
        cache_manager = CacheManager.new(enabled: true)
        cached = cache_manager.load_cached_analysis(original_path, @profile)
        if cached
          log "  Using cached analysis data"
          return cached
        end
      end

      # Measure using working path (local if staged)
      measured_data = FFmpegWrapper.measure_loudness(
        working_path,
        target_i: @profile[:lufs],
        target_tp: @profile[:tp],
        target_lra: @profile[:lra]
      )

      # Save cache using original path
      if @cache_enabled
        cache_manager = CacheManager.new(enabled: true)
        cache_manager.save_analysis(original_path, @profile, measured_data)
      end

      measured_data
    end

    def normalize_file_with_paths(original_path, working_path, measured_data)
      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

      current_lufs = measured_data['input_i'].to_f
      target_lufs = @profile[:lufs]
      adjustment = target_lufs - current_lufs

      audio_tracks = detect_audio_tracks(working_path)
      if audio_tracks.length > 1
        log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
      end

      log "  Current: #{current_lufs.round(1)} LUFS, Target: #{target_lufs} LUFS (#{adjustment.round(1)} LU adjustment)"

      codec_decision = FFmpegWrapper.apply_normalization_with_multiple_tracks(
        working_path, output_path, measured_data, audio_tracks, @profile
      )

      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise "Output file verification failed - processing aborted"
      end

      commit_output(original_path, working_path, output_path)
    rescue => e
      FileUtils.rm_f(output_path) if output_path && File.exist?(output_path)
      raise e
    end

    def commit_output(original_path, working_path, output_path)
      if @replace
        if @local_stage
          # Stage the processed file back to the original location
          @stager.stage_out(output_path, original_path)
          @stager.cleanup(output_path)
        else
          FileManager.atomic_replace(output_path, original_path)
        end
        log "  Replaced: #{original_path}"
      else
        dest = generate_output_path(original_path)
        if @local_stage
          @stager.stage_out(output_path, dest)
          @stager.cleanup(output_path)
        else
          # output_path is already in the right place
        end
        log "  Saved: #{dest}"
      end
    end
```

#### 7. Remove old analyze_loudness and normalize_file methods
- [x] Delete the old `analyze_loudness` method (`processor.rb` lines 292-307) — replaced by `analyze_loudness_for_path`
- [x] Delete the old `normalize_file` method (`processor.rb` lines 326-362) — replaced by `normalize_file_with_paths`

#### 8. Pass fast and local_stage through parallel config
- [x] Update the `config` hash in `process_files_parallel` (`processor.rb` line 202-210) to include the new options

Add after the `resume: false` line:
```ruby
        fast: @fast,
        local_stage: @local_stage
```

- [x] Update `ParallelProcessor#process_single_file` (`parallel_processor.rb` line 63-74) to pass the new options

Add to the `Processor.new` call:
```ruby
        fast: config[:fast],
        local_stage: config[:local_stage]
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec` — all tests pass (existing tests may need minor updates for refactored methods)

---

## Phase 4: Update Existing Tests and Add Integration Tests

### Overview
Update existing processor specs that reference the refactored methods, and add integration tests for the new flags.

### Tasks

#### 1. Update processor specs for refactored internals
- [x] Update `spec/processor_spec.rb` — the `#process_file` and `#normalize_file` tests may need adjustments since the internal method signatures changed. The key change: `process_file` now delegates to `process_file_two_pass` or `process_file_fast`, and `normalize_file` is replaced by `normalize_file_with_paths`.

Update the `#normalize_file` describe block to test `normalize_file_with_paths`:

```ruby
  describe '#normalize_file_with_paths' do
    let(:processor) { described_class.new(replace: false) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }
    let(:output_file) { File.join(temp_dir, 'movie_normalized.mp4') }
    let(:measured_data) do
      {
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      }
    end

    before do
      File.write(video_file, 'x')
      allow(processor).to receive(:detect_audio_tracks).and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256000, sample_rate: 48000 }])
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization_with_multiple_tracks).and_return(
        { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false }
      )
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
    end

    it 'writes to _normalized output in copy mode' do
      processor.send(:normalize_file_with_paths, video_file, video_file, measured_data)

      expect(Neutraliser::FFmpegWrapper).to have_received(:apply_normalization_with_multiple_tracks)
        .with(video_file, output_file, measured_data, any_args)
    end

    it 'raises when output fails integrity checks' do
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(output_file).and_return(true)
      allow(FileUtils).to receive(:rm_f)

      expect { processor.send(:normalize_file_with_paths, video_file, video_file, measured_data) }
        .to raise_error(/Output file verification failed/)
    end
  end
```

#### 2. Add fast mode processor specs
- [x] Add fast mode tests to `spec/processor_spec.rb`

```ruby
  describe '#process_file with fast mode' do
    let(:processor) { described_class.new(fast: true, dry_run: true) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'x')
    end

    it 'uses fast single-pass in dry-run mode' do
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)
      allow(FFMPEG::Movie).to receive(:new).and_return(movie)

      result = processor.send(:process_file, video_file)

      expect(result[:status]).to eq(:done)
      expect(result[:reason]).to eq(:dry_run)
    end
  end
```

#### 3. Add local staging processor specs
- [x] Add local staging tests to `spec/processor_spec.rb`

```ruby
  describe '#process_file with local staging' do
    let(:staging_dir) { Dir.mktmpdir }
    let(:processor) { described_class.new(local_stage: true, dry_run: true) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'video content')
    end

    after do
      FileUtils.remove_entry(staging_dir) if Dir.exist?(staging_dir)
    end

    it 'stages file locally before processing' do
      movie = instance_double(FFMPEG::Movie, path: anything, audio_stream: true)
      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:process_file_two_pass).and_return(
        { file: video_file, status: :done, reason: :dry_run, message: nil }
      )

      result = processor.send(:process_file, video_file)

      expect(result[:status]).to eq(:done)
    end

    it 'cleans up staged file after processing' do
      movie = instance_double(FFMPEG::Movie, path: anything, audio_stream: true)
      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:process_file_two_pass).and_return(
        { file: video_file, status: :done, reason: :dry_run, message: nil }
      )

      processor.send(:process_file, video_file)

      stager = processor.instance_variable_get(:@stager)
      staged_files = Dir.glob(File.join(stager.staging_dir, '*'))
      expect(staged_files).to be_empty
    end
  end
```

### Success Criteria

#### Automated Verification:
- [x] Run: `bundle exec rspec` — all tests pass
- [x] Run: `bundle exec rspec spec/processor_spec.rb` — all processor tests pass
- [x] Run: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` — all ffmpeg wrapper tests pass
- [x] Run: `bundle exec rspec spec/local_stager_spec.rb` — all stager tests pass

#### Manual Verification:
- [x] Manual: Process a real video file with `--fast` and verify output plays correctly
- [x] Manual: Process a real video file with `--local-stage` and verify output matches normal processing
- [x] Manual: Process a real video file with `--fast --local-stage` combined

---

## Phase 5: Update Documentation

### Overview
Update README and architecture docs so agents and users know about the new flags.

### Tasks

#### 1. Update README CLI options
- [x] Add `--fast` and `--local-stage` to the `process` command options list in `README.md` (after the `--resume` line)

```markdown
- **`--fast`**: Single-pass normalization — faster but slightly less accurate than two-pass.
- **`--local-stage`**: Copy files to local disk before processing — dramatically faster on network storage (SMB/NFS).
```

#### 2. Update architecture doc
- [x] Add a "Performance Flags" section to `docs/design/architecture.md` after the "Audio Codec Selection" section

```markdown
### Performance Flags

Two optional flags improve batch throughput, especially on network-attached storage:

- **`--local-stage`** — copies each file to a local temp directory (`/tmp/neutraliser_staging/`) before processing, then copies the result back. Avoids slow random I/O over SMB/NFS. The cache sidecar files are still read/written next to the original video, not the staged copy.
- **`--fast`** — uses FFmpeg's single-pass loudnorm (dynamic mode) instead of the default two-pass (linear mode). Skips the measurement pass entirely, halving I/O. Slightly less accurate — uses dynamic gain adjustment rather than a constant linear offset.

Both flags are independent and can be combined for maximum speed.
```

### Success Criteria

#### Automated Verification:
- [x] Run: `grep 'local-stage' README.md` — flag is documented
- [x] Run: `grep 'fast' docs/design/architecture.md` — flag is documented

---

## Final Checklist

- [x] All phases complete
- [x] All tests passing: `bundle exec rspec`
- [x] CLI help shows new options: `bundle exec neutraliser help process`
- [x] No leftover staged files after processing
- [x] README documents both new flags
- [x] Architecture doc describes the performance flags

## References

- Task: [docs/tasks/0005-local-staging-and-fast-mode/task.md](./task.md)
- Performance task: [docs/tasks/0003-performance-optimization/task.md](../0003-performance-optimization/task.md)
- FFmpeg loudnorm docs: http://k.ylo.ph/2016/04/04/loudnorm.html
- Architecture: `docs/design/architecture.md`
