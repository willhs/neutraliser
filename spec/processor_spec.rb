require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::Processor do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe '#initialize' do
    it 'uses livingroom profile by default' do
      processor = described_class.new
      profile = processor.instance_variable_get(:@profile)

      expect(profile).to include(name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0)
    end

    it 'uses exact custom target for target_level override' do
      processor = described_class.new(target_level: -18.3)
      profile = processor.instance_variable_get(:@profile)

      expect(profile).to include(name: 'custom', lufs: -18.3, tp: -1.5, lra: 12.0)
    end
  end

  describe '#process' do
    it 'exits for missing path' do
      processor = described_class.new

      expect { processor.process(File.join(temp_dir, 'missing.mp4')) }
        .to output(/does not exist/).to_stdout
        .and raise_error(SystemExit)
    end

    it 'processes directory sequentially' do
      processor = described_class.new
      video_1 = File.join(temp_dir, 'a.mp4')
      video_2 = File.join(temp_dir, 'b.mkv')
      File.write(video_1, 'x')
      File.write(video_2, 'x')

      expect(processor).to receive(:process_one).with(video_1).and_return(
        { file: video_1, status: :done, reason: :normalized, message: nil }
      )
      expect(processor).to receive(:process_one).with(video_2).and_return(
        { file: video_2, status: :skipped, reason: :within_tolerance, message: nil }
      )

      summary = processor.process(temp_dir)
      expect(summary[:done]).to eq(1)
      expect(summary[:skipped]).to eq(1)
    end

    it 'supports resuming from manifest and skips completed files' do
      processor = described_class.new(resume: true)
      completed = File.join(temp_dir, 'done.mp4')
      pending = File.join(temp_dir, 'todo.mkv')
      File.write(completed, 'x')
      File.write(pending, 'x')

      manifest_path = File.join(temp_dir, '.neutraliser-run-manifest.jsonl')
      File.open(manifest_path, 'w') do |manifest|
        manifest.puts(JSON.generate({
          timestamp: Time.now.utc.iso8601,
          file: File.expand_path(completed),
          status: 'done'
        }))
      end

      expect(processor).to receive(:process_one).with(pending).and_return(
        { file: pending, status: :done, reason: :normalized, message: nil }
      )
      expect(processor).not_to receive(:process_one).with(completed)

      summary = processor.process(temp_dir)
      expect(summary[:resumed]).to eq(1)
      expect(summary[:queued]).to eq(1)
      expect(summary[:done]).to eq(1)
      expect(summary[:failed]).to eq(0)
    end
  end

  describe '#process_file' do
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'video')
    end

    it 'skips unsupported file extensions' do
      txt = File.join(temp_dir, 'note.txt')
      File.write(txt, 'x')

      expect { described_class.new.send(:process_file, txt) }
        .to output(/not a supported video format/).to_stdout
    end

    it 'skips files with no audio stream' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, audio_stream: nil)
      allow(FFMPEG::Movie).to receive(:new).and_return(movie)

      expect { processor.send(:process_file, video_file) }
        .to output(/No audio track found, skipping/).to_stdout
    end

    it 'prints dry-run output using numeric conversion for measured input' do
      processor = described_class.new(dry_run: true)
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)
      measured = {
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      }

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      allow(processor).to receive(:needs_processing?).and_return(true)

      expect { processor.send(:process_file, video_file) }
        .to output(/\[DRY RUN\] Would normalize: -18.0 LUFS → -20.0 LUFS/).to_stdout
    end

    it 'handles analysis errors by reporting and continuing' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_raise(StandardError, 'analysis failed')

      expect { processor.send(:process_file, video_file) }
        .to output(/Error processing file: analysis failed/).to_stdout
    end
  end

  describe '#analyze_loudness_for_path' do
    let(:processor) { described_class.new }
    let(:analyser) { instance_double(Neutraliser::AudioAnalyser) }

    before do
      allow(Neutraliser::AudioAnalyser).to receive(:new).and_return(analyser)
    end

    it 'skips full analysis when fast verification indicates no work is needed' do
      allow(analyser).to receive(:should_analyze_file?).and_return(false)

      result = processor.send(:analyze_loudness_for_path, '/tmp/movie.mp4', '/tmp/movie.mp4')

      expect(result['fast_verified']).to eq(true)
      expect(result['target_offset']).to eq(0.0)
    end

    it 'raises ffmpeg errors from measurement instead of using fake fallback data' do
      allow(analyser).to receive(:should_analyze_file?).and_return(true)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_raise(Neutraliser::FFmpegError, 'boom')

      expect { processor.send(:analyze_loudness_for_path, '/tmp/movie.mp4', '/tmp/movie.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

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
end
