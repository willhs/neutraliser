require 'spec_helper'
require 'benchmark'
require 'tempfile'
require 'fileutils'

RSpec.describe 'Performance and Validation', :performance do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe 'Cache Performance' do
    let(:manager) { Neutraliser::CacheManager.new(enabled: true) }
    let(:video_file) { File.join(temp_dir, 'test.mp4') }
    let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
    let(:measured_data) do
      {
        'input_i' => '-18.5',
        'input_tp' => '-2.1',
        'input_lra' => '8.3',
        'input_thresh' => '-28.9',
        'target_offset' => '1.5'
      }
    end

    before do
      File.write(video_file, 'fake video content')
    end

    it 'saves and loads cache efficiently' do
      save_time = Benchmark.measure do
        100.times do |i|
          test_file = File.join(temp_dir, "video_#{i}.mp4")
          File.write(test_file, "content #{i}")
          manager.save_analysis(test_file, profile, measured_data)
        end
      end

      load_time = Benchmark.measure do
        100.times do |i|
          test_file = File.join(temp_dir, "video_#{i}.mp4")
          manager.load_cached_analysis(test_file, profile)
        end
      end

      expect(save_time.real).to be < 1.0, "Cache saves took #{save_time.real}s, expected < 1.0s"
      expect(load_time.real).to be < 0.5, "Cache loads took #{load_time.real}s, expected < 0.5s"
    end

    it 'scales well with many cache files' do
      # Create many cache files
      1000.times do |i|
        test_file = File.join(temp_dir, "video_#{i}.mp4")
        File.write(test_file, "content #{i}")
        manager.save_analysis(test_file, profile, measured_data)
      end

      # Test cache stats performance
      stats_time = Benchmark.measure do
        stats = manager.cache_stats(temp_dir)
        expect(stats[:total_files]).to eq(1000)
      end

      expect(stats_time.real).to be < 2.0, "Cache stats took #{stats_time.real}s for 1000 files"
    end

    it 'handles cache cleanup efficiently' do
      # Create cache files for cleanup test
      50.times do |i|
        test_file = File.join(temp_dir, "video_#{i}.mp4")
        File.write(test_file, "content #{i}")
        manager.save_analysis(test_file, profile, measured_data)
      end

      cleanup_time = Benchmark.measure do
        50.times do |i|
          test_file = File.join(temp_dir, "video_#{i}.mp4")
          manager.cleanup_stale_cache(test_file)
        end
      end

      expect(cleanup_time.real).to be < 1.0, "Cache cleanup took #{cleanup_time.real}s"
    end
  end

  describe 'Audio Analysis Performance' do
    let(:analyser) { Neutraliser::AudioAnalyser.new(cache_enabled: true, use_sidecar: true) }
    let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }

    before do
      # Mock FFmpeg calls for performance testing
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return({
        'input_i' => '-18.5',
        'input_tp' => '-2.1',
        'input_lra' => '8.3',
        'input_thresh' => '-28.9',
        'target_offset' => '1.5'
      })
    end

    it 'shows significant cache performance improvement' do
      video_file = File.join(temp_dir, 'test.mp4')
      File.write(video_file, 'fake video content')

      # First analysis (cache miss)
      first_analysis_time = Benchmark.measure do
        analyser.analyze_file(video_file, profile)
      end

      # Second analysis (cache hit)
      second_analysis_time = Benchmark.measure do
        analyser.analyze_file(video_file, profile)
      end

      # Cache hit should be significantly faster
      speedup_ratio = first_analysis_time.real / second_analysis_time.real
      expect(speedup_ratio).to be > 2.0, "Cache hit was only #{speedup_ratio}x faster"
    end

    it 'maintains good performance with tolerance calculations' do
      measured_data = { 'input_i' => '-18.5' }

      calculation_time = Benchmark.measure do
        1000.times do
          analyser.needs_normalization?(measured_data, profile, tolerance: 1.0)
        end
      end

      expect(calculation_time.real).to be < 0.1, "1000 tolerance calculations took #{calculation_time.real}s"
    end
  end

  describe 'File Manager Performance' do
    describe Neutraliser::FileManager do
      it 'performs atomic replacements efficiently' do
        source_files = []
        target_files = []

        # Create test files
        10.times do |i|
          source = File.join(temp_dir, "source_#{i}.mp4")
          target = File.join(temp_dir, "target_#{i}.mp4")

          File.write(source, "source content #{i}" * 1000)  # ~15KB files
          File.write(target, "target content #{i}")

          source_files << source
          target_files << target
        end

        replacement_time = Benchmark.measure do
          source_files.zip(target_files).each do |source, target|
            Neutraliser::FileManager.atomic_replace(source, target)
          end
        end

        expect(replacement_time.real).to be < 1.0, "10 atomic replacements took #{replacement_time.real}s"
      end

      it 'verifies file integrity efficiently' do
        test_files = []

        # Create test files with fake video headers
        20.times do |i|
          file = File.join(temp_dir, "video_#{i}.mp4")
          File.write(file, "ftypisom\x00\x00\x00\x20" + "\x00" * 1000)
          test_files << file
        end

        # Mock ffprobe for consistent timing
        allow(Open3).to receive(:capture3).and_return(['h264', '', double(success?: true)])

        verification_time = Benchmark.measure do
          test_files.each do |file|
            Neutraliser::FileManager.verify_file_integrity(file)
          end
        end

        expect(verification_time.real).to be < 2.0, "20 file verifications took #{verification_time.real}s"
      end
    end
  end

  describe 'Profile Lookup Performance' do
    describe Neutraliser::Profiles do
      it 'performs profile lookups efficiently' do
        lookup_time = Benchmark.measure do
          1000.times do
            # Mix of name and numeric lookups
            Neutraliser::Profiles.get_profile('livingroom')
            Neutraliser::Profiles.get_profile(-20.0)
            Neutraliser::Profiles.get_profile('night')
            Neutraliser::Profiles.get_profile(-16.0)
          end
        end

        expect(lookup_time.real).to be < 0.1, "4000 profile lookups took #{lookup_time.real}s"
      end

      it 'handles edge case lookups efficiently' do
        edge_case_time = Benchmark.measure do
          1000.times do
            # Test boundary values
            Neutraliser::Profiles.get_profile(-18.0)  # Between profiles
            Neutraliser::Profiles.get_profile(-21.5)  # Close to livingroom
            Neutraliser::Profiles.get_profile(-5.0)   # Far from any profile
          end
        end

        expect(edge_case_time.real).to be < 0.2, "3000 edge case lookups took #{edge_case_time.real}s"
      end
    end
  end

  describe 'FFmpeg Wrapper Performance' do
    describe Neutraliser::FFmpegWrapper do
      let(:sample_json_output) do
        <<~STDERR
          [Parsed_loudnorm_0 @ 0x12345678]
          {
            "input_i" : "-18.5",
            "input_tp" : "-2.1",
            "input_lra" : "8.3",
            "input_thresh" : "-28.9",
            "target_offset" : "1.5"
          }
        STDERR
      end

      before do
        allow(Open3).to receive(:capture3).and_return(['', sample_json_output, double(success?: true)])
      end

      it 'parses JSON output efficiently' do
        parsing_time = Benchmark.measure do
          100.times do
            Neutraliser::FFmpegWrapper.send(:parse_loudnorm_json, sample_json_output)
          end
        end

        expect(parsing_time.real).to be < 0.1, "100 JSON parses took #{parsing_time.real}s"
      end

      it 'handles audio track detection efficiently' do
        ffprobe_output = {
          'streams' => Array.new(20) do |i|
            if i < 5
              { 'index' => i, 'codec_type' => 'audio', 'codec_name' => 'aac', 'channels' => 2 }
            else
              { 'index' => i, 'codec_type' => 'video', 'codec_name' => 'h264' }
            end
          end
        }.to_json

        allow(Open3).to receive(:capture3).and_return([ffprobe_output, '', double(success?: true)])

        detection_time = Benchmark.measure do
          50.times do
            result = Neutraliser::FFmpegWrapper.detect_audio_tracks('test.mp4')
            expect(result.length).to eq(5)
          end
        end

        expect(detection_time.real).to be < 0.5, "50 audio track detections took #{detection_time.real}s"
      end
    end
  end

  describe 'Memory Usage Validation' do
    it 'does not leak memory during normal operations' do
      # Get baseline memory usage
      initial_memory = get_memory_usage

      processor = Neutraliser::Processor.new(cache: true)

      # Simulate processing multiple files
      100.times do |i|
        file_path = File.join(temp_dir, "video_#{i}.mp4")
        File.write(file_path, "fake content #{i}")

        # Mock the processing without actual FFmpeg
        allow(FFMPEG::Movie).to receive(:new).and_return(
          double(path: file_path, audio_stream: true)
        )

        allow(processor).to receive(:analyze_loudness).and_return({
          'input_i' => '-18.0',
          'fallback' => false
        })

        allow(processor).to receive(:needs_processing?).and_return(false)

        processor.send(:process_file, file_path)
      end

      final_memory = get_memory_usage
      memory_growth = final_memory - initial_memory

      # Should not have significant memory growth (allow 20MB)
      expect(memory_growth).to be < 20_000, "Memory grew by #{memory_growth}KB"
    end

    private

    def get_memory_usage
      `ps -o rss= -p #{Process.pid}`.to_i
    end
  end

  describe 'Concurrent Performance' do
    it 'handles concurrent operations efficiently' do
      # Test concurrent cache operations
      threads = []
      manager = Neutraliser::CacheManager.new(enabled: true)
      profile = { name: 'test', lufs: -20.0 }

      concurrent_time = Benchmark.measure do
        5.times do |thread_id|
          threads << Thread.new do
            20.times do |i|
              file_path = File.join(temp_dir, "thread#{thread_id}_file#{i}.mp4")
              File.write(file_path, "content #{thread_id}-#{i}")

              data = { 'input_i' => "#{-20 - i}", 'thread' => thread_id }
              manager.save_analysis(file_path, profile, data)
              manager.load_cached_analysis(file_path, profile)
            end
          end
        end

        threads.each(&:join)
      end

      expect(concurrent_time.real).to be < 2.0, "Concurrent operations took #{concurrent_time.real}s"
    end
  end

  describe 'Accuracy Validation' do
    describe 'LUFS Calculation Precision' do
      let(:analyser) { Neutraliser::AudioAnalyser.new }

      it 'maintains precision in tolerance calculations' do
        test_cases = [
          { current: -19.99, target: -20.0, tolerance: 0.1, should_process: true },
          { current: -19.95, target: -20.0, tolerance: 0.1, should_process: false },
          { current: -20.05, target: -20.0, tolerance: 0.1, should_process: false },
          { current: -20.11, target: -20.0, tolerance: 0.1, should_process: true },
        ]

        test_cases.each do |test_case|
          measured_data = { 'input_i' => test_case[:current].to_s }
          profile = { lufs: test_case[:target] }

          result = analyser.needs_normalization?(
            measured_data, profile, tolerance: test_case[:tolerance]
          )

          expect(result).to eq(test_case[:should_process]),
            "Failed for current: #{test_case[:current]}, target: #{test_case[:target]}, " \
            "tolerance: #{test_case[:tolerance]}. Expected: #{test_case[:should_process]}, got: #{result}"
        end
      end
    end

    describe 'Profile Matching Accuracy' do
      it 'matches closest profiles correctly' do
        test_cases = [
          { input: -22.9, expected: 'reference' },
          { input: -23.1, expected: 'reference' },
          { input: -19.9, expected: 'livingroom' },
          { input: -20.1, expected: 'livingroom' },
          { input: -15.9, expected: 'night' },
          { input: -16.1, expected: 'night' },
        ]

        test_cases.each do |test_case|
          result = Neutraliser::Profiles.get_profile(test_case[:input])
          expect(result[:name]).to eq(test_case[:expected]),
            "Input #{test_case[:input]} should match #{test_case[:expected]}, got #{result[:name]}"
        end
      end
    end

    describe 'File Extension Detection' do
      let(:processor) { Neutraliser::Processor.new }

      it 'correctly identifies all supported formats' do
        supported_extensions = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v]

        supported_extensions.each do |ext|
          test_files = [
            "movie#{ext}",
            "MOVIE#{ext.upcase}",
            "movie.with.dots#{ext}",
            "/path/to/movie#{ext}"
          ]

          test_files.each do |filename|
            result = processor.send(:video_file?, filename)
            expect(result).to be true, "Failed to identify #{filename} as video file"
          end
        end
      end

      it 'correctly rejects unsupported formats' do
        unsupported_files = %w[
          movie.mp3 movie.txt movie.jpg movie.pdf
          movie.docx movie.zip movie.exe movie.wav
        ]

        unsupported_files.each do |filename|
          result = processor.send(:video_file?, filename)
          expect(result).to be false, "Incorrectly identified #{filename} as video file"
        end
      end
    end
  end

  describe 'Resource Cleanup Validation' do
    it 'cleans up temporary files properly' do
      processor = Neutraliser::Processor.new(replace: true)

      # Create some temp files to simulate processing
      temp_files = []
      5.times do |i|
        temp_file = File.join(temp_dir, "temp_neutraliser_#{i}.mp4")
        File.write(temp_file, "temp content #{i}")
        temp_files << temp_file
      end

      # Mock glob to return our temp files
      pattern = "*_neutraliser_*"
      allow(Dir).to receive(:glob).with(pattern).and_return(temp_files)
      allow(FileUtils).to receive(:rm).and_call_original

      processor.send(:cleanup_temp_files)

      temp_files.each do |temp_file|
        expect(FileUtils).to have_received(:rm).with(temp_file)
      end
    end

    it 'validates file integrity consistently' do
      test_files = []

      # Create files with different validity
      valid_file = File.join(temp_dir, 'valid.mp4')
      File.write(valid_file, "ftypisom\x00\x00\x00\x20" + "\x00" * 100)
      test_files << { file: valid_file, valid: true }

      empty_file = File.join(temp_dir, 'empty.mp4')
      File.write(empty_file, '')
      test_files << { file: empty_file, valid: false }

      invalid_file = File.join(temp_dir, 'invalid.mp4')
      File.write(invalid_file, 'not a video file')
      test_files << { file: invalid_file, valid: false }

      test_files.each do |test_case|
        if test_case[:valid]
          allow(Open3).to receive(:capture3)
            .with('ffprobe', '-v', 'error', '-select_streams', 'v:0',
                  '-show_entries', 'stream=codec_name', '-of', 'csv=p=0',
                  test_case[:file])
            .and_return(['h264', '', double(success?: true)])
        else
          allow(Open3).to receive(:capture3)
            .with('ffprobe', '-v', 'error', '-select_streams', 'v:0',
                  '-show_entries', 'stream=codec_name', '-of', 'csv=p=0',
                  test_case[:file])
            .and_return(['', 'Invalid data', double(success?: false)])
        end

        result = Neutraliser::FileManager.verify_file_integrity(test_case[:file])
        expect(result).to eq(test_case[:valid]),
          "File #{test_case[:file]} should be #{test_case[:valid] ? 'valid' : 'invalid'}"
      end
    end
  end
end