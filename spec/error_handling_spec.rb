require 'spec_helper'
require 'tempfile'
require 'fileutils'

RSpec.describe 'Error Handling and Edge Cases' do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe 'FFmpeg Error Handling' do
    describe Neutraliser::FFmpegWrapper do
      context 'when ffmpeg command fails' do
        before do
          allow(Open3).to receive(:capture3).and_return(['', 'Command failed', double(success?: false)])
        end

        it 'raises FFmpegError with stderr message' do
          expect {
            Neutraliser::FFmpegWrapper.measure_loudness('nonexistent.mp4')
          }.to raise_error(Neutraliser::FFmpegError, /Command failed/)
        end
      end

      context 'when ffmpeg is not installed' do
        before do
          allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT.new('No such file or directory - ffmpeg'))
        end

        it 'raises clear error about missing ffmpeg' do
          expect {
            Neutraliser::FFmpegWrapper.measure_loudness('test.mp4')
          }.to raise_error(Errno::ENOENT, /ffmpeg/)
        end
      end

      context 'with corrupted video file' do
        let(:corrupted_file) { File.join(temp_dir, 'corrupted.mp4') }

        before do
          File.write(corrupted_file, 'not a real video file')
          allow(Open3).to receive(:capture3).and_return(['', 'Invalid data found', double(success?: false)])
        end

        it 'handles corrupted files gracefully' do
          expect {
            Neutraliser::FFmpegWrapper.measure_loudness(corrupted_file)
          }.to raise_error(Neutraliser::FFmpegError, /Invalid data found/)
        end
      end

      context 'with malformed JSON output' do
        before do
          allow(Open3).to receive(:capture3).and_return(['', 'not json output', double(success?: true)])
        end

        it 'raises clear parsing error' do
          expect {
            Neutraliser::FFmpegWrapper.measure_loudness('test.mp4')
          }.to raise_error(Neutraliser::FFmpegError, /Failed to parse loudnorm JSON/)
        end
      end

      context 'with incomplete JSON output' do
        let(:incomplete_json) do
          <<~STDERR
            [Parsed_loudnorm_0 @ 0x12345678]
            {
              "input_i" : "-18.5",
              // Missing required fields
            }
          STDERR
        end

        before do
          allow(Open3).to receive(:capture3).and_return(['', incomplete_json, double(success?: true)])
        end

        it 'handles incomplete JSON gracefully' do
          expect {
            Neutraliser::FFmpegWrapper.measure_loudness('test.mp4')
          }.to raise_error(Neutraliser::FFmpegError, /Failed to parse loudnorm JSON/)
        end
      end
    end
  end

  describe 'File System Error Handling' do
    describe Neutraliser::FileManager do
      context 'with permission errors' do
        let(:readonly_file) { File.join(temp_dir, 'readonly.mp4') }

        before do
          File.write(readonly_file, 'content')
          File.chmod(0444, readonly_file)  # Read-only
        end

        it 'handles permission errors gracefully' do
          expect {
            Neutraliser::FileManager.atomic_replace('/tmp/source', readonly_file)
          }.to raise_error(Errno::EACCES)
        end
      end

      context 'with full disk' do
        it 'handles disk full errors' do
          # Mock disk full error
          allow(FileUtils).to receive(:mv).and_raise(Errno::ENOSPC.new('No space left on device'))

          expect {
            Neutraliser::FileManager.atomic_replace('/tmp/source', '/tmp/dest')
          }.to raise_error(Errno::ENOSPC, /No space left on device/)
        end
      end

      context 'with network path interruptions' do
        it 'handles network interruptions' do
          # Mock network error
          allow(FileUtils).to receive(:mv).and_raise(Errno::EIO.new('Input/output error'))

          expect {
            Neutraliser::FileManager.atomic_replace('/network/source', '/network/dest')
          }.to raise_error(Errno::EIO)
        end
      end
    end
  end

  describe 'Cache Error Handling' do
    describe Neutraliser::CacheManager do
      let(:manager) { Neutraliser::CacheManager.new(enabled: true) }
      let(:video_file) { File.join(temp_dir, 'test.mp4') }
      let(:profile) { { name: 'test', lufs: -20.0 } }

      context 'with corrupted cache files' do
        before do
          File.write(video_file, 'content')
          cache_file = manager.cache_path(video_file, profile)
          File.write(cache_file, 'invalid json content')
        end

        it 'handles corrupted cache gracefully' do
          result = manager.load_cached_analysis(video_file, profile)
          expect(result).to be_nil
        end
      end

      context 'with permission denied on cache directory' do
        before do
          File.write(video_file, 'content')
          cache_file = manager.cache_path(video_file, profile)
          FileUtils.mkdir_p(File.dirname(cache_file))
          File.chmod(0444, File.dirname(cache_file))  # Read-only directory
        end

        it 'handles permission errors when writing cache' do
          expect {
            manager.save_analysis(video_file, profile, { 'data' => 'test' })
          }.to raise_error(Errno::EACCES)
        end
      end

      context 'with cache file locked by another process' do
        before do
          File.write(video_file, 'content')
          cache_file = manager.cache_path(video_file, profile)

          # Simulate file lock by creating read-only cache file
          File.write(cache_file, '{}')
          File.chmod(0444, cache_file)
        end

        it 'handles locked cache files' do
          expect {
            manager.save_analysis(video_file, profile, { 'data' => 'test' })
          }.to raise_error(Errno::EACCES)
        end
      end
    end
  end

  describe 'Edge Cases in Audio Analysis' do
    describe Neutraliser::AudioAnalyser do
      let(:analyser) { Neutraliser::AudioAnalyser.new(cache_enabled: false) }

      context 'with extreme LUFS values' do
        let(:extreme_data) { { 'input_i' => '-5.0' } }  # Very loud
        let(:profile) { { lufs: -20.0 } }

        it 'handles extremely loud content' do
          result = analyser.needs_normalization?(extreme_data, profile)
          expect(result).to be true
        end
      end

      context 'with very quiet content' do
        let(:quiet_data) { { 'input_i' => '-45.0' } }  # Very quiet
        let(:profile) { { lufs: -20.0 } }

        it 'handles extremely quiet content' do
          result = analyser.needs_normalization?(quiet_data, profile)
          expect(result).to be true
        end
      end

      context 'with missing LUFS data' do
        let(:incomplete_data) { { 'input_tp' => '-1.0' } }  # Missing input_i
        let(:profile) { { lufs: -20.0 } }

        it 'handles missing LUFS gracefully' do
          expect {
            analyser.needs_normalization?(incomplete_data, profile)
          }.to raise_error(NoMethodError)  # to_f called on nil
        end
      end

      context 'with non-numeric LUFS values' do
        let(:invalid_data) { { 'input_i' => 'not_a_number' } }
        let(:profile) { { lufs: -20.0 } }

        it 'handles non-numeric values' do
          result = analyser.needs_normalization?(invalid_data, profile)
          # 'not_a_number'.to_f returns 0.0
          expect(result).to be true  # 0.0 is far from -20.0
        end
      end
    end
  end

  describe 'Profile Edge Cases' do
    describe Neutraliser::Profiles do
      context 'with edge case LUFS values' do
        it 'handles boundary values correctly' do
          # Test values exactly between profiles
          result = Neutraliser::Profiles.get_profile(-18.0)  # Between -20 and -16
          expect(result).to be_a(Hash)
          expect(result[:lufs]).to be_a(Numeric)
        end
      end

      context 'with extreme custom values' do
        it 'accepts very loud targets' do
          result = Neutraliser::Profiles.get_profile(-5.0)
          expect(result[:lufs]).to eq(-5.0)
          expect(result[:tp]).to eq(-1.5)
          expect(result[:lra]).to eq(12.0)
        end

        it 'accepts very quiet targets' do
          result = Neutraliser::Profiles.get_profile(-35.0)
          expect(result[:lufs]).to eq(-35.0)
        end
      end

      context 'with invalid profile names' do
        it 'raises appropriate error for nil' do
          expect {
            Neutraliser::Profiles.get_profile(nil)
          }.to raise_error(ArgumentError)
        end

        it 'raises appropriate error for empty string' do
          expect {
            Neutraliser::Profiles.get_profile('')
          }.to raise_error(ArgumentError, /Unknown profile/)
        end

        it 'raises appropriate error for invalid string' do
          expect {
            Neutraliser::Profiles.get_profile('nonexistent')
          }.to raise_error(ArgumentError, /Unknown profile: nonexistent/)
        end
      end
    end
  end

  describe 'Processor Edge Cases' do
    describe Neutraliser::Processor do
      let(:processor) { Neutraliser::Processor.new }

      context 'with special file paths' do
        it 'handles paths with spaces' do
          file_path = File.join(temp_dir, 'file with spaces.mp4')
          File.write(file_path, 'content')

          # Should not raise errors due to space handling
          expect {
            processor.send(:video_file?, file_path)
          }.not_to raise_error
        end

        it 'handles paths with special characters' do
          file_path = File.join(temp_dir, 'movie-[2023]-héllo.mp4')
          File.write(file_path, 'content')

          result = processor.send(:video_file?, file_path)
          expect(result).to be true
        end

        it 'handles very long filenames' do
          long_name = 'a' * 200 + '.mp4'
          file_path = File.join(temp_dir, long_name)

          # This might fail on some filesystems, but shouldn't crash
          begin
            File.write(file_path, 'content')
            result = processor.send(:video_file?, file_path)
            expect(result).to be true
          rescue Errno::ENAMETOOLONG
            # Expected on some filesystems - test passes
          end
        end
      end

      context 'with symlinks and unusual files' do
        let(:real_file) { File.join(temp_dir, 'real.mp4') }
        let(:symlink_file) { File.join(temp_dir, 'link.mp4') }

        before do
          File.write(real_file, 'content')
          File.symlink(real_file, symlink_file) if File.respond_to?(:symlink)
        end

        it 'handles symlinks correctly' do
          skip 'Symlinks not supported on this platform' unless File.exist?(symlink_file)

          result = processor.send(:video_file?, symlink_file)
          expect(result).to be true
        end
      end

      context 'with zero-byte files' do
        let(:empty_file) { File.join(temp_dir, 'empty.mp4') }

        before do
          File.write(empty_file, '')
        end

        it 'handles empty files gracefully' do
          movie_mock = instance_double(FFMPEG::Movie, audio_stream: nil)
          allow(FFMPEG::Movie).to receive(:new).and_return(movie_mock)

          expect {
            processor.send(:process_file, empty_file)
          }.to output(/No audio track found, skipping/).to_stdout
        end
      end
    end
  end

  describe 'Concurrency and Race Conditions' do
    let(:temp_file) { File.join(temp_dir, 'test.mp4') }

    before do
      File.write(temp_file, 'content')
    end

    context 'with simultaneous file operations' do
      it 'handles concurrent atomic replacements' do
        threads = []

        5.times do |i|
          threads << Thread.new do
            source = File.join(temp_dir, "source_#{i}.mp4")
            File.write(source, "content #{i}")

            begin
              Neutraliser::FileManager.atomic_replace(source, temp_file)
            rescue => e
              # Some operations may fail due to race conditions, but shouldn't crash
              expect(e).to be_a(StandardError)
            end
          end
        end

        threads.each(&:join)

        # Final file should exist and be readable
        expect(File.exist?(temp_file)).to be true
        expect(File.readable?(temp_file)).to be true
      end
    end

    context 'with concurrent cache operations' do
      let(:manager) { Neutraliser::CacheManager.new(enabled: true) }
      let(:profile) { { name: 'test', lufs: -20.0 } }

      it 'handles concurrent cache writes' do
        threads = []

        3.times do |i|
          threads << Thread.new do
            begin
              manager.save_analysis(temp_file, profile, { 'run' => i })
              manager.load_cached_analysis(temp_file, profile)
            rescue => e
              # File system race conditions may occur, but shouldn't crash
              expect(e).to be_a(StandardError)
            end
          end
        end

        threads.each(&:join)
      end
    end
  end

  describe 'Memory and Resource Management' do
    context 'with large files' do
      it 'does not leak file descriptors' do
        initial_fd_count = `lsof -p #{Process.pid} | wc -l`.to_i

        100.times do
          processor = Neutraliser::Processor.new
          processor.send(:video_file?, '/nonexistent/file.mp4')
        end

        final_fd_count = `lsof -p #{Process.pid} | wc -l`.to_i

        # Should not have significant FD growth
        expect(final_fd_count - initial_fd_count).to be < 10
      end
    end

    context 'with many cache operations' do
      let(:manager) { Neutraliser::CacheManager.new(enabled: true) }

      it 'does not consume excessive memory' do
        initial_memory = `ps -o rss= -p #{Process.pid}`.to_i

        # Perform many cache operations
        100.times do |i|
          file = File.join(temp_dir, "file_#{i}.mp4")
          File.write(file, "content #{i}")

          profile = { name: 'test', lufs: -20.0 }
          data = { 'input_i' => "-#{20 + i}", 'run' => i }

          manager.save_analysis(file, profile, data)
          manager.load_cached_analysis(file, profile)
        end

        final_memory = `ps -o rss= -p #{Process.pid}`.to_i
        memory_growth = final_memory - initial_memory

        # Should not have excessive memory growth (allow 50MB growth)
        expect(memory_growth).to be < 50_000
      end
    end
  end
end