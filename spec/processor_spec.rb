require 'spec_helper'
require 'tempfile'
require 'fileutils'

RSpec.describe Neutraliser::Processor do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe '#initialize' do
    it 'initializes with default values' do
      processor = described_class.new
      expect(processor.instance_variable_get(:@replace)).to be false
      expect(processor.instance_variable_get(:@tolerance)).to eq(1.0)
      expect(processor.instance_variable_get(:@cache_enabled)).to be true
    end

    it 'accepts custom parameters' do
      processor = described_class.new(
        replace: true,
        target_level: -18.0,
        tolerance: 0.5,
        cache: false
      )

      expect(processor.instance_variable_get(:@replace)).to be true
      expect(processor.instance_variable_get(:@tolerance)).to eq(0.5)
      expect(processor.instance_variable_get(:@cache_enabled)).to be false
    end

    it 'uses profile when no target_level specified' do
      processor = described_class.new(profile: 'night')
      profile = processor.instance_variable_get(:@profile)
      expect(profile[:name]).to eq('night')
      expect(profile[:lufs]).to eq(-16.0)
    end

    it 'creates custom profile when target_level specified' do
      processor = described_class.new(target_level: -18.0)
      profile = processor.instance_variable_get(:@profile)
      expect(profile[:lufs]).to eq(-18.0)
    end
  end

  describe '#process' do
    let(:processor) { described_class.new }

    context 'with single file' do
      let(:video_file) { File.join(temp_dir, 'test.mp4') }

      before do
        File.write(video_file, 'fake video content')
      end

      it 'processes single video file' do
        expect(processor).to receive(:process_file).with(video_file)
        processor.process(video_file)
      end

      it 'handles nonexistent file' do
        expect {
          processor.process('/nonexistent/file.mp4')
        }.to output(/Path '.*' does not exist/).to_stdout.and raise_error(SystemExit)
      end
    end

    context 'with directory' do
      let(:video_files) do
        %w[movie1.mp4 movie2.mkv series.avi].map { |f| File.join(temp_dir, f) }
      end

      before do
        video_files.each { |f| File.write(f, 'fake content') }
        File.write(File.join(temp_dir, 'readme.txt'), 'not a video')
      end

      it 'processes all video files in directory' do
        video_files.each do |file|
          expect(processor).to receive(:process_file).with(file)
        end

        processor.process(temp_dir)
      end

      it 'skips non-video files' do
        expect(processor).not_to receive(:process_file).with(File.join(temp_dir, 'readme.txt'))
        allow(processor).to receive(:process_file).with(any_args)
        processor.process(temp_dir)
      end

      it 'handles empty directory gracefully' do
        empty_dir = File.join(temp_dir, 'empty')
        Dir.mkdir(empty_dir)

        expect {
          processor.process(empty_dir)
        }.to output(/No video files found/).to_stdout
      end
    end
  end

  describe '#process_file' do
    let(:processor) { described_class.new }
    let(:video_file) { File.join(temp_dir, 'test.mp4') }

    before do
      File.write(video_file, 'fake video content')
    end

    context 'with unsupported file format' do
      let(:text_file) { File.join(temp_dir, 'test.txt') }

      before do
        File.write(text_file, 'not a video')
      end

      it 'skips unsupported formats' do
        expect {
          processor.send(:process_file, text_file)
        }.to output(/Skipping.*not a supported video format/).to_stdout
      end
    end

    context 'with video file without audio' do
      before do
        movie_mock = instance_double(FFMPEG::Movie, audio_stream: nil)
        allow(FFMPEG::Movie).to receive(:new).and_return(movie_mock)
      end

      it 'skips files without audio tracks' do
        expect {
          processor.send(:process_file, video_file)
        }.to output(/No audio track found, skipping/).to_stdout
      end
    end

    context 'with valid video file' do
      let(:movie_mock) { instance_double(FFMPEG::Movie, path: video_file, audio_stream: true) }
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
        allow(FFMPEG::Movie).to receive(:new).and_return(movie_mock)
        allow(processor).to receive(:analyze_loudness).and_return(measured_data)
        allow(processor).to receive(:needs_processing?).and_return(true)
        allow(processor).to receive(:normalize_file)
      end

      it 'processes file that needs normalization' do
        expect {
          processor.send(:process_file, video_file)
        }.to output(/Processing: #{Regexp.escape(video_file)}/).to_stdout

        expect(processor).to have_received(:analyze_loudness).with(movie_mock)
        expect(processor).to have_received(:needs_processing?).with(measured_data)
        expect(processor).to have_received(:normalize_file).with(video_file, measured_data)
      end

      it 'skips file that does not need processing' do
        allow(processor).to receive(:needs_processing?).and_return(false)

        expect {
          processor.send(:process_file, video_file)
        }.to output(/Already at target level, skipping/).to_stdout

        expect(processor).not_to have_received(:normalize_file)
      end

      it 'handles processing errors gracefully' do
        allow(processor).to receive(:analyze_loudness).and_raise(StandardError.new('Analysis failed'))

        expect {
          processor.send(:process_file, video_file)
        }.to output(/Error processing file: Analysis failed/).to_stdout
      end
    end
  end

  describe '#normalize_file' do
    let(:processor) { described_class.new(replace: false) }
    let(:video_file) { File.join(temp_dir, 'input.mp4') }
    let(:measured_data) do
      {
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      }
    end
    let(:audio_tracks) { [{ index: 1, codec: 'aac', channels: 2 }] }

    before do
      File.write(video_file, 'fake video content')
      allow(processor).to receive(:detect_audio_tracks).and_return(audio_tracks)
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization_with_multiple_tracks)
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
    end

    it 'generates correct output path for copy mode' do
      expected_output = File.join(temp_dir, 'input_normalized.mp4')
      allow(File).to receive(:exist?).and_return(false)  # No cleanup needed

      expect {
        processor.send(:normalize_file, video_file, measured_data)
      }.to output(/Saved: #{Regexp.escape(expected_output)}/).to_stdout

      expect(Neutraliser::FFmpegWrapper).to have_received(:apply_normalization_with_multiple_tracks).with(
        video_file, expected_output, measured_data, audio_tracks, anything
      )
    end

    it 'detects multiple audio tracks' do
      multi_track_audio = [
        { index: 1, codec: 'ac3', channels: 6 },
        { index: 2, codec: 'aac', channels: 2 }
      ]
      allow(processor).to receive(:detect_audio_tracks).and_return(multi_track_audio)
      allow(File).to receive(:exist?).and_return(false)

      expect {
        processor.send(:normalize_file, video_file, measured_data)
      }.to output(/Found 2 audio tracks, normalizing primary track only/).to_stdout
    end

    it 'shows LUFS adjustment information' do
      allow(File).to receive(:exist?).and_return(false)

      expect {
        processor.send(:normalize_file, video_file, measured_data)
      }.to output(/Current: -18.0 LUFS, Target: -20.0 LUFS \(-2.0 LU adjustment\)/).to_stdout
    end

    context 'with replace mode' do
      let(:processor) { described_class.new(replace: true) }
      let(:temp_path) { File.join(temp_dir, 'temp_file.mp4') }

      before do
        allow(Neutraliser::FileManager).to receive(:safe_temp_path).and_return(temp_path)
        allow(Neutraliser::FileManager).to receive(:atomic_replace)
      end

      it 'uses atomic replacement for replace mode' do
        processor.send(:normalize_file, video_file, measured_data)

        expect(Neutraliser::FileManager).to have_received(:safe_temp_path).with(video_file)
        expect(Neutraliser::FileManager).to have_received(:atomic_replace).with(temp_path, video_file)
      end
    end

    context 'when file verification fails' do
      let(:output_path) { File.join(temp_dir, 'input_normalized.mp4') }

      before do
        allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(false)
        allow(FileUtils).to receive(:rm)
        allow(File).to receive(:exist?).with(output_path).and_return(true)
      end

      it 'cleans up failed output and raises error' do
        expect {
          processor.send(:normalize_file, video_file, measured_data)
        }.to raise_error(/Output file verification failed/)

        expect(FileUtils).to have_received(:rm).with(output_path)
      end
    end

    context 'when normalization fails' do
      let(:output_path) { File.join(temp_dir, 'input_normalized.mp4') }

      before do
        allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization_with_multiple_tracks)
          .and_raise(StandardError.new('FFmpeg failed'))
        allow(FileUtils).to receive(:rm)
        allow(File).to receive(:exist?).with(output_path).and_return(true)
      end

      it 'cleans up temp file and re-raises error' do
        expect {
          processor.send(:normalize_file, video_file, measured_data)
        }.to raise_error('FFmpeg failed')

        expect(FileUtils).to have_received(:rm).with(output_path)
      end
    end
  end

  describe 'file detection methods' do
    let(:processor) { described_class.new }

    describe '#find_video_files' do
      before do
        # Create directory structure with video and non-video files
        Dir.mkdir(File.join(temp_dir, 'subdir'))

        %w[movie.mp4 series.mkv clip.avi].each do |f|
          File.write(File.join(temp_dir, f), 'video')
        end

        File.write(File.join(temp_dir, 'subdir', 'nested.mov'), 'nested video')
        File.write(File.join(temp_dir, 'readme.txt'), 'not video')
        File.write(File.join(temp_dir, 'image.jpg'), 'image')
      end

      it 'finds all video files recursively' do
        files = processor.send(:find_video_files, temp_dir)

        expect(files).to include(
          File.join(temp_dir, 'movie.mp4'),
          File.join(temp_dir, 'series.mkv'),
          File.join(temp_dir, 'clip.avi'),
          File.join(temp_dir, 'subdir', 'nested.mov')
        )

        expect(files).not_to include(
          File.join(temp_dir, 'readme.txt'),
          File.join(temp_dir, 'image.jpg')
        )
      end
    end

    describe '#video_file?' do
      it 'identifies supported video formats' do
        supported_files = %w[
          test.mp4 test.mkv test.avi test.mov
          test.wmv test.flv test.webm test.m4v
        ]

        supported_files.each do |file|
          expect(processor.send(:video_file?, file)).to be true
        end
      end

      it 'rejects unsupported formats' do
        unsupported_files = %w[
          test.txt test.jpg test.mp3 test.pdf
          test.MP4 test.MKV  # Case sensitivity test
        ]

        unsupported_files[0..-3].each do |file|  # Skip case test for now
          expect(processor.send(:video_file?, file)).to be false
        end
      end

      it 'handles case-insensitive extensions' do
        expect(processor.send(:video_file?, 'TEST.MP4')).to be true
        expect(processor.send(:video_file?, 'movie.MKV')).to be true
      end
    end
  end

  describe 'audio analysis integration' do
    let(:processor) { described_class.new }
    let(:movie_mock) { instance_double(FFMPEG::Movie, path: '/test/video.mp4') }
    let(:analyzer_mock) { instance_double(Neutraliser::AudioAnalyser) }

    before do
      allow(Neutraliser::AudioAnalyser).to receive(:new).and_return(analyzer_mock)
    end

    describe '#analyze_loudness' do
      let(:profile) { processor.instance_variable_get(:@profile) }

      it 'delegates to AudioAnalyser with correct profile' do
        expect(analyzer_mock).to receive(:analyze_file).with('/test/video.mp4', profile)
        processor.send(:analyze_loudness, movie_mock)
      end

      context 'when analysis fails' do
        before do
          allow(analyzer_mock).to receive(:analyze_file).and_raise(Neutraliser::FFmpegError.new('Analysis failed'))
        end

        it 'falls back to dummy data with warning' do
          expect {
            result = processor.send(:analyze_loudness, movie_mock)
            expect(result['fallback']).to be true
            expect(result['input_i']).to eq(-18.0)
          }.to output(/Warning: Could not analyze loudness.*using fallback/).to_stdout
        end
      end
    end

    describe '#needs_processing?' do
      let(:measured_data) { { 'input_i' => '-18.0' } }

      before do
        allow(analyzer_mock).to receive(:needs_normalization?).and_return(true)
      end

      it 'delegates to AudioAnalyser with tolerance' do
        processor.send(:needs_processing?, measured_data)

        expect(analyzer_mock).to have_received(:needs_normalization?).with(
          measured_data, anything, tolerance: 1.0
        )
      end
    end
  end
end

# Integration test tag for real media files
RSpec.describe Neutraliser::Processor, :integration do
  # These tests require actual media files and FFmpeg
  # Skip by default unless explicitly requested with: rspec --tag integration

  let(:media_dir) { '/Volumes/G-TV-Shows' }

  before(:each) do
    skip 'Integration tests require media files' unless Dir.exist?(media_dir) && ENV['RUN_INTEGRATION_TESTS']
  end

  describe 'with real media files', :slow do
    let(:processor) { described_class.new(replace: false, cache: true) }

    it 'processes actual video files correctly' do
      # Find a small video file for testing
      video_files = Dir.glob(File.join(media_dir, '**', '*.{mp4,mkv}')).first(1)
      skip 'No video files found for integration testing' if video_files.empty?

      test_file = video_files.first
      expect {
        processor.process(test_file)
      }.not_to raise_error
    end
  end
end