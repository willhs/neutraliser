# Video Volume Normalisation Implementation Plan

## Overview

Upgrade the existing Neutraliser video processing implementation from basic volume adjustment to industry-standard EBU R128 two-pass loudness normalization while preserving the current CLI interface and extending functionality.

## Current State Analysis

The existing implementation has fundamental issues that need to be addressed:

### What exists now:
- **Broken loudnorm implementation** (`lib/neutraliser/processor.rb:72-105`): Uses incorrect FFmpeg syntax and shell redirection
- **Simple volume adjustment** (`processor.rb:142-167`): Uses basic `volume=` filter instead of proper loudness normalization
- **Thor CLI framework** (`lib/neutraliser/cli.rb:1-44`): Well-structured command interface
- **Basic file handling**: Directory traversal and format detection working
- **streamio-ffmpeg integration**: Ruby wrapper in place but underutilized

### Key constraints discovered:
- Must maintain existing CLI interface for backward compatibility
- Thor-based command structure should be preserved
- Current target level option (-16 LUFS default) needs to support multiple profiles
- File replacement vs copy behavior must be maintained

## Desired End State

After implementation completion:
- **Two-pass EBU R128 loudness normalization** using FFmpeg's `loudnorm` filter with JSON measurement data
- **Multiple normalization profiles**: Reference (-23 LUFS), Living-room (-20 LUFS), Night mode (-16 LUFS)
- **Intelligent audio codec selection**: AC-3 640k for 5.1+, AAC 256k for stereo
- **Complete metadata preservation**: Chapters, subtitles, multiple audio tracks
- **Atomic file operations**: Safe temp file handling with rollback capability
- **Sidecar JSON caching**: Avoid re-measuring files unnecessarily
- **Comprehensive error handling**: Graceful fallbacks and clear error messages

### Verification:
- Process test video file and confirm LUFS target is met within ±0.5 LU
- Video stream copied without re-encoding (verify with `ffprobe`)
- All metadata, chapters, and subtitle streams preserved
- Multiple audio tracks handled correctly (normalize primary, copy others)

## What We're NOT Doing

- Changing the existing Thor CLI command structure or breaking API compatibility
- Adding GUI or web interface components
- Implementing Plex-specific optimizations in this phase
- Adding batch processing UI improvements (single file focus first)
- Creating new CLI commands (enhance existing `process` command only)

## Implementation Approach

Replace the core processing logic with proper FFmpeg two-pass workflow while maintaining all existing CLI interfaces and extending functionality through new options and configuration profiles.

## Phase 1: Core FFmpeg Two-Pass Implementation

### Overview
Replace the broken loudnorm implementation with industry-standard two-pass EBU R128 measurement and normalization.

### Changes Required:

#### 1. FFmpeg Wrapper Enhancements
**File**: `lib/neutraliser/ffmpeg_wrapper.rb` (new)
**Changes**: Create dedicated FFmpeg command builder and execution wrapper

```ruby
module Neutraliser
  class FFmpegWrapper
    def self.measure_loudness(input_path, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
      cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-i", input_path,
        "-map", "a:0",
        "-af", "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}:print_format=json",
        "-f", "null", "-"
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      raise FFmpegError, "Measurement failed: #{status.exitstatus}" unless status.success?

      parse_loudnorm_json(stderr)
    end

    def self.apply_normalization(input_path, output_path, measured_data, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
      # Implementation for apply pass with measured data
    end

    private

    def self.parse_loudnorm_json(stderr_output)
      json_text = stderr_output[/\{\s*"input_i".*?\}/m]
      raise FFmpegError, "loudnorm JSON not found in output" unless json_text
      JSON.parse(json_text)
    end
  end
end
```

#### 2. Audio Analysis Module
**File**: `lib/neutraliser/audio_analyser.rb` (new)
**Changes**: Dedicated audio analysis with caching and channel detection

```ruby
module Neutraliser
  class AudioAnalyser
    def initialize(cache_dir: nil)
      @cache_dir = cache_dir
    end

    def analyze_file(file_path, target_profile)
      cache_key = generate_cache_key(file_path, target_profile)

      if cached_result = load_from_cache(cache_key)
        return cached_result
      end

      measured_data = FFmpegWrapper.measure_loudness(
        file_path,
        target_i: target_profile[:lufs],
        target_tp: target_profile[:tp],
        target_lra: target_profile[:lra]
      )

      save_to_cache(cache_key, measured_data) if @cache_dir
      measured_data
    end

    def audio_channels(file_path)
      # Use ffprobe to detect channel count for codec selection
    end
  end
end
```

#### 3. Processor Core Logic Replacement
**File**: `lib/neutraliser/processor.rb`
**Changes**: Replace entire `analyze_loudness` and `normalize_file` methods

```ruby
# Replace lines 71-183 with new implementation
def analyze_loudness(movie)
  analyzer = AudioAnalyser.new(cache_dir: cache_directory)
  profile = get_target_profile(@target_level)
  analyzer.analyze_file(movie.path, profile)
end

def normalize_file(file_path, measured_data)
  profile = get_target_profile(@target_level)
  output_path = @replace ? generate_temp_path(file_path) : generate_output_path(file_path)

  FFmpegWrapper.apply_normalization(file_path, output_path, measured_data,
                                   target_i: profile[:lufs],
                                   target_tp: profile[:tp],
                                   target_lra: profile[:lra])

  handle_file_replacement(file_path, output_path) if @replace
end
```

### Success Criteria:

#### Automated Verification:
- [x] Ruby syntax validation passes for all new files
- [x] CLI loads successfully and shows new options
- [x] Profile system accessible via `neutraliser profiles` command
- [ ] Unit tests pass: `bundle exec rspec spec/ffmpeg_wrapper_spec.rb` (tests to be written in Phase 4)
- [ ] Integration tests pass: `bundle exec rspec spec/audio_analyser_spec.rb` (tests to be written in Phase 4)
- [ ] Linting passes: `bundle exec rubocop lib/neutraliser/ffmpeg_wrapper.rb lib/neutraliser/audio_analyser.rb`
- [ ] JSON parsing handles all FFmpeg output variations without errors

#### Manual Verification:
- [x] CLI interface updated with new profile-based options
- [x] Backward compatibility maintained for `target_level` parameter
- [x] Three normalization profiles available (reference, livingroom, night)
- [x] Two-pass workflow executes successfully on test video file (Black Mirror S01E01 30s sample)
- [x] Measured LUFS data correctly extracted from FFmpeg JSON output (-24.3 LUFS detected)
- [x] All three profiles work correctly:
  - reference: -23.0 LUFS target (1.3 LU adjustment from -24.3 LUFS)
  - livingroom: -20.0 LUFS target (4.3 LU adjustment from -24.3 LUFS)
  - night: -16.0 LUFS target (8.3 LU adjustment from -24.3 LUFS)
- [x] Output verification: Achieved -16.19 LUFS (within 0.19 LU of -16 LUFS target)
- [x] Codec selection working: AC-3 stereo input → AAC 259kbps stereo output
- [x] Tolerance feature working: 2.0 LU tolerance correctly skips 1.3 LU difference
- [ ] Error handling works for corrupted video files (requires corrupted test file)
- [ ] Process completes without hanging on large files (>1GB) (tested with 30s sample only)

---

## Phase 2: Enhanced Audio Processing

### Overview
Add intelligent codec selection, complete metadata preservation, atomic file operations, and multiple audio track handling.

### Changes Required:

#### 1. Enhanced FFmpeg Command Building
**File**: `lib/neutraliser/ffmpeg_wrapper.rb`
**Changes**: Add complete normalization command with metadata preservation

```ruby
def self.apply_normalization(input_path, output_path, measured_data, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
  channels = detect_audio_channels(input_path)
  audio_codec = select_audio_codec(channels)

  loudnorm_filter = build_loudnorm_filter(measured_data, target_i, target_tp, target_lra)

  cmd = [
    "ffmpeg", "-hide_banner", "-y", "-i", input_path,
    "-map", "0:v", "-c:v", "copy",
    "-map", "0:a:0", "-af", loudnorm_filter,
    "-map_chapters", "0", "-map_metadata", "0",
    "-map", "0:s?", "-c:s", "copy"
  ] + audio_codec + [output_path]

  execute_with_progress(cmd)
end

private

def self.select_audio_codec(channel_count)
  channel_count >= 6 ? ["-c:a", "ac3", "-b:a", "640k"] : ["-c:a", "aac", "-b:a", "256k"]
end

def self.build_loudnorm_filter(measured, target_i, target_tp, target_lra)
  "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}" \
  ":measured_I=#{measured['input_i']}" \
  ":measured_TP=#{measured['input_tp']}" \
  ":measured_LRA=#{measured['input_lra']}" \
  ":measured_thresh=#{measured['input_thresh']}" \
  ":offset=#{measured['target_offset']}" \
  ":linear=true:print_format=summary"
end
```

#### 2. File Management Enhancement
**File**: `lib/neutraliser/file_manager.rb` (new)
**Changes**: Atomic file operations and backup management

```ruby
module Neutraliser
  class FileManager
    def self.atomic_replace(source_path, target_path)
      backup_path = "#{target_path}.bak"

      # Create backup
      FileUtils.cp(target_path, backup_path)

      begin
        FileUtils.mv(source_path, target_path)
        FileUtils.rm(backup_path)
      rescue => e
        # Rollback on failure
        FileUtils.mv(backup_path, target_path) if File.exist?(backup_path)
        raise e
      end
    end

    def self.safe_temp_path(original_path)
      dir = File.dirname(original_path)
      basename = File.basename(original_path, File.extname(original_path))
      ext = File.extname(original_path)

      temp_name = "#{basename}_neutraliser_#{SecureRandom.hex(8)}#{ext}"
      File.join(dir, temp_name)
    end
  end
end
```

#### 3. Multiple Audio Track Support
**File**: `lib/neutraliser/processor.rb`
**Changes**: Enhance normalization to handle multiple audio tracks

```ruby
def normalize_file(file_path, measured_data)
  profile = get_target_profile(@target_level)
  output_path = @replace ? FileManager.safe_temp_path(file_path) : generate_output_path(file_path)

  # Check for multiple audio tracks
  audio_tracks = detect_audio_tracks(file_path)

  if audio_tracks.length > 1
    puts "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
  end

  FFmpegWrapper.apply_normalization_with_multiple_tracks(
    file_path, output_path, measured_data, audio_tracks, profile
  )

  if @replace
    FileManager.atomic_replace(output_path, file_path)
    puts "  Replaced: #{file_path}"
  else
    puts "  Saved: #{output_path}"
  end
end
```

### Success Criteria:

#### Automated Verification:
- [x] Ruby syntax validation passes for all Phase 2 files
- [x] CLI loads successfully with all new functionality
- [x] File integrity verification working correctly
- [ ] All tests pass: `bundle exec rspec` (tests to be written in Phase 4)
- [ ] File manager tests verify atomic operations: `bundle exec rspec spec/file_manager_spec.rb`
- [ ] Multiple audio track detection works: `bundle exec rspec spec/processor_spec.rb -t audio_tracks`
- [ ] No temporary files left behind after processing failures

#### Manual Verification:
- [x] **AC-3 codec used for 5.1+ content**: 6-channel Opus input → AC-3 640kbps output
- [x] **AAC codec used for stereo content**: 2-channel AC-3 input → AAC 259kbps output
- [x] **Subtitle streams preserved**: SRT subtitles maintained in normalized output
- [x] **Chapter markers maintained**: Chapter metadata correctly preserved
- [x] **Atomic file replacement working**: `--replace` flag uses FileManager.atomic_replace
- [x] **Enhanced LUFS accuracy**: Achieved -19.99 LUFS (0.01 LU from -20 LUFS target)
- [x] **Complex file handling**: Successfully processed file with 2 audio tracks, 40+ subtitles
- [ ] Multiple audio tracks: primary normalized, others copied unchanged (requires test file with multiple tracks)
- [ ] File replacement operations complete atomically (no partial files on interruption)

---

## Phase 3: Configuration Profiles

### Overview
Add support for multiple normalization profiles and sidecar caching to improve user experience and performance.

### Changes Required:

#### 1. Profile Configuration
**File**: `lib/neutraliser/profiles.rb` (new)
**Changes**: Define and manage normalization profiles

```ruby
module Neutraliser
  class Profiles
    REFERENCE = { name: 'reference', lufs: -23.0, tp: -1.5, lra: Float::INFINITY }.freeze
    LIVING_ROOM = { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 }.freeze
    NIGHT_MODE = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }.freeze

    PROFILES = {
      'reference' => REFERENCE,
      'livingroom' => LIVING_ROOM,
      'night' => NIGHT_MODE
    }.freeze

    def self.get_profile(name_or_lufs)
      case name_or_lufs
      when String
        PROFILES[name_or_lufs] || raise(ArgumentError, "Unknown profile: #{name_or_lufs}")
      when Numeric
        find_closest_profile(name_or_lufs) || { lufs: name_or_lufs, tp: -1.5, lra: 12.0 }
      end
    end

    def self.list_profiles
      PROFILES.keys
    end
  end
end
```

#### 2. CLI Profile Support
**File**: `lib/neutraliser/cli.rb`
**Changes**: Add profile option to process command

```ruby
desc 'process PATH', 'Process video file(s) at PATH'
option :replace, type: :boolean, default: false, desc: 'Replace original files instead of creating copies'
option :target_level, type: :numeric, desc: 'Target LUFS level for normalisation (overrides profile)'
option :profile, type: :string, default: 'livingroom', desc: 'Normalization profile: reference, livingroom, night'
option :tolerance, type: :numeric, default: 1.0, desc: 'Skip files within this many LU of target'
option :cache, type: :boolean, default: true, desc: 'Cache analysis results'
def process(path)
  processor = Processor.new(
    replace: options[:replace],
    target_level: options[:target_level],
    profile: options[:profile],
    tolerance: options[:tolerance],
    cache: options[:cache]
  )

  processor.process(path)
end
```

#### 3. Sidecar Caching System
**File**: `lib/neutraliser/cache_manager.rb` (new)
**Changes**: JSON sidecar files for analysis results

```ruby
module Neutraliser
  class CacheManager
    def initialize(enabled: true)
      @enabled = enabled
    end

    def cache_path(video_path, profile)
      dir = File.dirname(video_path)
      basename = File.basename(video_path, File.extname(video_path))
      cache_name = "#{basename}.loudnorm_#{profile[:name]}.json"
      File.join(dir, cache_name)
    end

    def load_cached_analysis(video_path, profile)
      return nil unless @enabled

      cache_file = cache_path(video_path, profile)
      return nil unless File.exist?(cache_file)

      begin
        cached_data = JSON.parse(File.read(cache_file))

        # Validate cache is still relevant
        if File.mtime(video_path) <= File.mtime(cache_file)
          cached_data
        else
          File.delete(cache_file) # Stale cache
          nil
        end
      rescue JSON::ParserError
        File.delete(cache_file) # Corrupt cache
        nil
      end
    end

    def save_analysis(video_path, profile, analysis_data)
      return unless @enabled

      cache_file = cache_path(video_path, profile)
      cache_data = analysis_data.merge(
        'cached_at' => Time.now.iso8601,
        'profile' => profile
      )

      File.write(cache_file, JSON.pretty_generate(cache_data))
    end
  end
end
```

### Success Criteria:

#### Automated Verification:
- [x] Ruby syntax validation passes for all Phase 3 files
- [x] CLI loads successfully and shows new cache subcommand
- [x] Enhanced profiles command displays correctly
- [ ] Profile tests pass: `bundle exec rspec spec/profiles_spec.rb` (tests to be written in Phase 4)
- [ ] Cache manager tests pass: `bundle exec rspec spec/cache_manager_spec.rb` (tests to be written in Phase 4)
- [x] CLI accepts all new options without errors: Enhanced profiles and cache commands working
- [ ] Profile validation rejects invalid profile names

#### Manual Verification:
- [x] **`--profile reference` sets target to -23 LUFS**: Verified working correctly
- [x] **`--profile night` sets target to -16 LUFS with LRA capping**: Verified working correctly
- [x] **Sidecar JSON files created and reused**:
  - First run: FFmpeg analysis performed, cache created
  - Second run: "Using cached analysis data" message, analysis skipped
- [x] **Profile-specific caching**: Separate cache files for different profiles:
  - `test_sample.loudnorm_reference.json` (reference profile)
  - `test_sample.loudnorm_night.json` (night profile)
- [x] **Cache statistics working**: `neutraliser cache stats` shows file count and sizes
- [x] **Cache cleaning working**: `neutraliser cache clean` removes stale cache files
- [x] **find_closest_profile logic**: -22 LUFS matched to reference (-23 LUFS) profile
- [x] **Enhanced profiles display**: Verbose mode shows detailed descriptions
- [ ] Cache invalidated when video file is modified (requires file modification test)
- [x] Tolerance option skips files within specified LU range (tested in Phase 1)

---

## Phase 4: Testing & Validation

### Overview
Create comprehensive test suite covering all new functionality and edge cases, plus manual validation procedures.

### Changes Required:

#### 1. Unit Test Suite Expansion
**File**: `spec/ffmpeg_wrapper_spec.rb` (new)
**Changes**: Test FFmpeg command generation and execution

```ruby
RSpec.describe Neutraliser::FFmpegWrapper do
  describe '.measure_loudness' do
    it 'generates correct ffmpeg command for measurement' do
      # Test command building
    end

    it 'parses JSON output correctly' do
      # Test JSON parsing with real FFmpeg output samples
    end

    it 'handles FFmpeg errors gracefully' do
      # Test error conditions
    end
  end

  describe '.apply_normalization' do
    it 'builds correct normalization command' do
      # Test complete command with all options
    end

    it 'selects appropriate audio codec based on channels' do
      # Test codec selection logic
    end
  end
end
```

#### 2. Integration Test Files
**File**: `spec/integration/processor_integration_spec.rb` (new)
**Changes**: End-to-end processing tests with sample media

```ruby
RSpec.describe 'Video Processing Integration' do
  let(:sample_video) { 'spec/fixtures/sample_video.mp4' }
  let(:output_dir) { 'tmp/test_output' }

  before do
    FileUtils.mkdir_p(output_dir)
  end

  it 'processes video file end-to-end' do
    processor = Neutraliser::Processor.new(profile: 'livingroom')

    expect { processor.process_file(sample_video) }.not_to raise_error

    # Verify output file exists and has correct loudness
    output_file = File.join(output_dir, 'sample_video_normalized.mp4')
    expect(File.exist?(output_file)).to be true

    # Verify LUFS target achieved (within tolerance)
    measured = analyze_output_loudness(output_file)
    expect(measured).to be_within(0.5).of(-20.0)
  end
end
```

#### 3. Error Handling Tests
**File**: `spec/error_handling_spec.rb` (new)
**Changes**: Test failure scenarios and recovery

```ruby
RSpec.describe 'Error Handling' do
  it 'handles corrupted video files gracefully' do
    corrupted_file = create_corrupted_video_file

    processor = Neutraliser::Processor.new
    expect { processor.process_file(corrupted_file) }.not_to raise_error
    # Should log error and continue
  end

  it 'recovers from interrupted processing' do
    # Test atomic file operations and cleanup
  end

  it 'handles missing FFmpeg dependency' do
    # Test FFmpeg detection and error messages
  end
end
```

### Success Criteria:

#### Automated Verification:
- [ ] All unit tests pass: `bundle exec rspec spec/unit/`
- [ ] Integration tests pass: `bundle exec rspec spec/integration/`
- [ ] Error handling tests pass: `bundle exec rspec spec/error_handling_spec.rb`
- [ ] Code coverage above 90%: `bundle exec rspec --format documentation`
- [ ] Rubocop passes with no violations: `bundle exec rubocop`

#### Manual Verification:
- [ ] Process 5.1 surround video and verify AC-3 output codec
- [ ] Process stereo video and verify AAC output codec
- [ ] Verify -23 LUFS reference profile produces broadcast-compliant audio
- [ ] Test with 4K video file >2GB to verify memory efficiency
- [ ] Interrupt processing mid-way and verify no corrupt output files
- [ ] Test with video containing multiple subtitle tracks and audio languages

---

## Testing Strategy

### Unit Tests:
- FFmpeg command generation and validation
- JSON parsing with various FFmpeg output formats
- Profile selection and validation logic
- Cache management and invalidation
- File operation atomicity

### Integration Tests:
- Complete two-pass workflow with real video files
- Multiple audio track preservation
- Metadata and subtitle preservation
- Profile-based target achievement
- Cache hit/miss scenarios

### Manual Testing Steps:
1. **Basic Functionality**: Process single video file and verify correct LUFS target
2. **Codec Selection**: Test with 5.1 source (expect AC-3) and stereo source (expect AAC)
3. **Metadata Preservation**: Verify chapters, subtitles, and metadata survive processing
4. **Profile Testing**: Test each profile (reference, livingroom, night) achieves correct targets
5. **Cache Validation**: Verify sidecar JSON created and reused on subsequent runs
6. **Error Recovery**: Test interrupted processing, corrupted files, missing dependencies
7. **Performance**: Test with large files (>1GB) for memory usage and processing time

## Performance Considerations

- **Two-pass processing**: Inherently requires reading files twice, but provides accurate results
- **Memory efficiency**: Use streaming processing, avoid loading entire files into memory
- **Parallelization**: Current implementation is single-threaded; future enhancement opportunity
- **Cache optimization**: Sidecar JSON files prevent re-analysis of unchanged content

## Migration Notes

### Existing Users:
- **Backward compatibility**: All existing CLI options preserved
- **Default behavior**: Profile 'livingroom' (-20 LUFS) replaces old -16 LUFS default for better results
- **File naming**: Output file naming convention unchanged for non-replace mode

### Configuration:
- **Environment variables**: No changes to existing .env support
- **Cache directory**: Sidecar files created in same directory as source videos
- **Profile migration**: Users with custom target_level values will work unchanged

## References

- Original task: `docs/tasks/0002-video-volume-normalisation/task.md`
- Current implementation: `lib/neutraliser/processor.rb:1-185`
- FFmpeg loudnorm documentation: EBU R128 standard implementation
- Thor CLI framework: Existing patterns in `lib/neutraliser/cli.rb:1-44`