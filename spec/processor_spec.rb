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

    it 'records normalization_type per file in the run manifest' do
      processor = described_class.new
      video = File.join(temp_dir, 'a.mp4')
      File.write(video, 'x')

      expect(processor).to receive(:process_one).with(video).and_return(
        { file: video, status: :done, reason: :normalized, message: nil, normalization_type: 'Dynamic' }
      )

      summary = processor.process(temp_dir)
      manifest_lines = File.readlines(summary[:manifest_path]).map { |line| JSON.parse(line) }
      done_entry = manifest_lines.find { |entry| entry['status'] == 'done' }

      expect(done_entry['normalization_type']).to eq('Dynamic')
    end
  end

  describe '#process_file' do
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'video')
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks)
        .and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
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
      measured = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      )

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)

      expect { processor.send(:process_file, video_file) }
        .to output(/\[DRY RUN\] Would normalize: -18.0 LUFS → -20.0 LUFS/).to_stdout
    end

    it 'does not mark a file processed during a dry run' do
      # Regression: a dry run returns status :done, which used to satisfy the
      # mark-processed condition and stamp the sidecar. The real run that
      # followed then skipped the file as already normalised, silently
      # leaving it untouched — the exact sequence the README recommends.
      processor = described_class.new(dry_run: true)
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)
      measured = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-40.0',
        'input_tp' => '-12.0',
        'input_lra' => '8.0',
        'input_thresh' => '-50.0',
        'target_offset' => '0.0'
      )
      skip_decider = instance_double(Neutraliser::SkipDecider, already_processed?: false)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      processor.instance_variable_set(:@skip_decider, skip_decider)

      expect(skip_decider).not_to receive(:mark_processed)

      result = nil
      expect { result = processor.send(:process_file, video_file) }.to output(/DRY RUN/).to_stdout
      expect(result[:reason]).to eq(:dry_run)
    end

    it 'handles analysis errors by reporting and continuing' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_raise(StandardError, 'analysis failed')

      expect { processor.send(:process_file, video_file) }
        .to output(/Error processing file: analysis failed/).to_stdout
    end

    it 'records a distinct :timeout reason for FFmpegTimeoutError, not the generic processing_error bucket' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      result = nil
      expect { result = processor.send(:process_file, video_file) }
        .to output(/Timed out processing file: timed out/).to_stdout

      expect(result[:status]).to eq(:failed)
      expect(result[:reason]).to eq(:timeout)
    end

    it 'records a distinct :output_verification_failed reason, not the generic processing_error bucket' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::OutputVerificationError, 'Output file verification failed - processing aborted')

      result = nil
      expect { result = processor.send(:process_file, video_file) }
        .to output(/Output verification failed/).to_stdout

      expect(result[:status]).to eq(:failed)
      expect(result[:reason]).to eq(:output_verification_failed)
    end

    it 'records a distinct :ffmpeg_error reason for a non-timeout FFmpegError' do
      processor = described_class.new
      movie = instance_double(FFMPEG::Movie, path: video_file, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegError, 'corrupt container')

      result = processor.send(:process_file, video_file)

      expect(result[:status]).to eq(:failed)
      expect(result[:reason]).to eq(:ffmpeg_error)
    end
  end

  describe 'preflight checks' do
    let(:show_dir) { File.join(temp_dir, 'The Simpsons') }
    let(:episodes) { %w[s01e01.mkv s01e02.mkv].map { |name| File.join(show_dir, name) } }

    before do
      FileUtils.mkdir_p(show_dir)
      episodes.each { |episode| File.write(episode, 'x') }
      allow(Neutraliser::FFmpegWrapper).to receive(:unsupported_subtitles).and_return([])
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(nil)
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_return(nil)
    end

    after { FileUtils.chmod(0o755, show_dir) }

    it 'fails every file in a folder it cannot write to as :not_writable, before any analysis' do
      FileUtils.chmod(0o555, show_dir)
      processor = described_class.new(replace: true)
      expect(FFMPEG::Movie).not_to receive(:new)
      expect(processor).not_to receive(:analyze_loudness_for_path)

      summary = nil
      expect { summary = processor.process(show_dir) }
        .to output(/Not writable — fix permissions on 1 folder\(s\):\n.*The Simpsons/).to_stdout

      expect(summary[:results].map { |r| r[:reason] }).to eq(%i[not_writable not_writable])
      expect(summary[:results].first[:message]).to eq("can't write to #{File.expand_path(show_dir)} (Permission denied); fix the folder's permissions")
      expect(summary[:failed_by_reason]).to eq(not_writable: 2)
      expect(summary[:not_writable_dirs]).to eq([File.expand_path(show_dir)])
      expect(Dir.children(show_dir).grep(/write-check/)).to be_empty
    end

    it 'leaves no trace of the write check in a writable folder' do
      processor = described_class.new
      allow(FFMPEG::Movie).to receive(:new).and_return(instance_double(FFMPEG::Movie, audio_stream: nil))

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }.to output.to_stdout

      expect(result[:reason]).to eq(:no_audio_track)
      expect(Dir.children(show_dir)).to contain_exactly('s01e01.mkv', 's01e02.mkv')
    end

    it 'does not check writability on a dry run, which writes nothing' do
      FileUtils.chmod(0o555, show_dir)
      processor = described_class.new(dry_run: true)
      allow(FFMPEG::Movie).to receive(:new).and_return(instance_double(FFMPEG::Movie, audio_stream: nil))

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }.to output.to_stdout

      expect(result[:reason]).to eq(:no_audio_track)
    end

    it 'fails a file whose subtitles ffmpeg cannot copy as :unsupported_subtitle, before any analysis' do
      allow(Neutraliser::FFmpegWrapper).to receive(:unsupported_subtitles)
        .with(episodes.first).and_return(['stream 2 (S_TEXT/WEBVTT)'])
      processor = described_class.new
      expect(FFMPEG::Movie).not_to receive(:new)

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }
        .to output(/Unsupported subtitle: subtitle stream 2 \(S_TEXT\/WEBVTT\)/).to_stdout

      expect(result).to include(status: :failed, reason: :unsupported_subtitle)
      expect(result[:message]).to start_with("subtitle stream 2 (S_TEXT/WEBVTT) can't be copied")
    end

    it 'takes the failure reason an FFmpegError recognised from the encode' do
      processor = described_class.new
      allow(FFMPEG::Movie).to receive(:new).and_return(instance_double(FFMPEG::Movie, audio_stream: true))
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([{ codec: 'aac' }])
      allow(Neutraliser::ObjectAudio).to receive(:detect).and_return(Neutraliser::ObjectAudio::NONE)
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegError.new('Normalization failed (exit 1): Subtitle codec 0 is not supported.',
                                                reason: :unsupported_subtitle))

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }.to output.to_stdout

      expect(result).to include(status: :failed, reason: :unsupported_subtitle,
                                message: 'Normalization failed (exit 1): Subtitle codec 0 is not supported.')
    end
  end

  describe '#analyze_loudness_for_path' do
    let(:processor) { described_class.new }
    let(:analyser) { instance_double(Neutraliser::AudioAnalyser) }
    let(:profile) { processor.instance_variable_get(:@profile) }

    before do
      allow(Neutraliser::AudioAnalyser).to receive(:new).and_return(analyser)
    end

    it 'delegates to AudioAnalyser#analyze with staging paths, caching under the original path' do
      measurement = Neutraliser::Measurement.already_at_target(profile)
      expect(analyser).to receive(:analyze)
        .with('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile, tolerance: 1.0)
        .and_return(measurement)

      result = processor.send(:analyze_loudness_for_path, '/working/movie.mp4', '/orig/movie.mp4')

      expect(result).to eq(measurement)
    end

    it 'raises ffmpeg errors from measurement instead of using fake fallback data' do
      allow(analyser).to receive(:analyze).and_raise(Neutraliser::FFmpegError, 'boom')

      expect { processor.send(:analyze_loudness_for_path, '/tmp/movie.mp4', '/tmp/movie.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

  describe '#normalize_file_with_paths' do
    let(:processor) { described_class.new(replace: false) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }
    let(:output_file) { File.join(temp_dir, 'movie_normalized.mp4') }
    let(:measured_data) do
      Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      )
    end

    before do
      File.write(video_file, 'x')
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization).and_return(
        { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false }
      )
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
    end

    it 'writes to _normalized output in copy mode' do
      processor.send(:normalize_file_with_paths, video_file, video_file, measured_data)

      expect(Neutraliser::FFmpegWrapper).to have_received(:apply_normalization)
        .with(video_file, output_file, measured_data, any_args)
    end

    it 'raises a distinct OutputVerificationError when output fails integrity checks' do
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(output_file).and_return(true)
      allow(FileUtils).to receive(:rm_f)

      expect { processor.send(:normalize_file_with_paths, video_file, video_file, measured_data) }
        .to raise_error(Neutraliser::OutputVerificationError, /Output file verification failed/)
    end

    it 'returns the codec decision including normalization_type' do
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization).and_return(
        { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false, normalization_type: 'Dynamic' }
      )

      result = processor.send(:normalize_file_with_paths, video_file, video_file, measured_data)

      expect(result[:normalization_type]).to eq('Dynamic')
    end

    it 'passes allow_dynamic through to FFmpegWrapper' do
      linear_processor = described_class.new(replace: false, allow_dynamic: true)
      File.write(video_file, 'x')
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)

      linear_processor.send(:normalize_file_with_paths, video_file, video_file, measured_data)

      expect(Neutraliser::FFmpegWrapper).to have_received(:apply_normalization)
        .with(video_file, output_file, measured_data, anything, hash_including(allow_dynamic: true))
    end

    it 'cleans up the temp output file even when interrupted (not just on StandardError)' do
      allow(processor).to receive(:commit_output).and_raise(Interrupt)

      expect { processor.send(:normalize_file_with_paths, video_file, video_file, measured_data) }
        .to raise_error(Interrupt)

      expect(File.exist?(output_file)).to be(false)
    end

    it 'does not delete the output file once commit_output has already succeeded' do
      # Simulate the real artifact commit_output would produce/leave in place
      # (in copy mode, output_path *is* the final deliverable - the ensure
      # cleanup must not remove it just because it still exists on disk).
      File.write(output_file, 'normalized content')
      allow(processor).to receive(:commit_output)

      processor.send(:normalize_file_with_paths, video_file, video_file, measured_data)

      expect(File.exist?(output_file)).to be(true)
    end
  end

  describe '#commit_output with local staging and replace' do
    let(:processor) { described_class.new(replace: true, local_stage: true) }
    let(:original_file) { File.join(temp_dir, 'movie.mp4') }
    let(:staged_output) { File.join(temp_dir, 'staged_output.mp4') }

    before do
      File.write(original_file, 'original content')
      File.write(staged_output, 'normalized content')
    end

    it 'replaces the original atomically via FileManager instead of copying straight over it' do
      expect(Neutraliser::FileManager).to receive(:atomic_copy).and_call_original

      processor.send(:commit_output, original_file, staged_output)

      expect(File.read(original_file)).to eq('normalized content')
    end

    it 'leaves the original file untouched if the atomic copy step fails' do
      allow(Neutraliser::FileManager).to receive(:atomic_copy).and_raise(Neutraliser::FileManagerError, 'boom')

      expect { processor.send(:commit_output, original_file, staged_output) }
        .to raise_error(Neutraliser::FileManagerError, /boom/)

      expect(File.read(original_file)).to eq('original content')
    end
  end

  describe 'dynamic opt-in' do
    it 'defaults to constant gain' do
      processor = described_class.new
      expect(processor.instance_variable_get(:@allow_dynamic)).to be(false)
    end

    it 'is implied by the night profile' do
      processor = described_class.new(profile: 'night')
      expect(processor.instance_variable_get(:@allow_dynamic)).to be(true)
    end

    it 'is not implied by livingroom or reference' do
      %w[livingroom reference].each do |name|
        expect(described_class.new(profile: name).instance_variable_get(:@allow_dynamic)).to be(false)
      end
    end

    it 'refuses --fast without allow_dynamic or a dynamic profile' do
      expect { described_class.new(fast: true) }.to raise_error(ArgumentError, /--fast.*--allow-dynamic/)
    end

    it 'allows --fast with allow_dynamic or the night profile' do
      expect { described_class.new(fast: true, allow_dynamic: true) }.not_to raise_error
      expect { described_class.new(fast: true, profile: 'night') }.not_to raise_error
    end
  end

  describe 'run reporting' do
    let(:processor) { described_class.new }

    it 'counts Linear and Dynamic files in the summary' do
      results = [
        { status: :done, normalization_type: 'Linear' },
        { status: :done, normalization_type: 'Linear' },
        { status: :done, normalization_type: 'Dynamic' },
        { status: :skipped, normalization_type: nil }
      ]

      summary = processor.send(:summarize_results, found: 4, queued: 4, resumed: 0, manifest_path: nil, results: results)

      expect(summary).to include(linear: 2, dynamic: 1)
    end

    it 'warns when a file went Dynamic' do
      expect(Neutraliser.logger).to receive(:log).with(/Warning: file went Dynamic/).at_least(:once)
      allow(Neutraliser.logger).to receive(:log)

      processor.send(:log_codec_decision, encoder: 'aac', bitrate: 128_000, normalization_type: 'Dynamic')
    end

    it 'logs the shortfall when the gain was peak-capped' do
      expect(Neutraliser.logger).to receive(:log).with(/Peak-capped: landed 8.5 LU short of -20.0 LUFS/)
      allow(Neutraliser.logger).to receive(:log)

      processor.send(:log_codec_decision, encoder: 'aac', bitrate: 128_000, normalization_type: 'Linear', shortfall_lu: 8.5)
    end
  end

  describe '#process_file with fast mode' do
    let(:processor) { described_class.new(fast: true, allow_dynamic: true, dry_run: true) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'x')
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks)
        .and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
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
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks)
        .and_return([{ index: 0, codec: 'aac', channels: 2, bit_rate: 256_000, sample_rate: 48_000 }])
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
      staged_files = Dir.glob(File.join(stager.instance_variable_get(:@staging_dir), '*'))
      expect(staged_files).to be_empty
    end

    it 'cleans up the staged input when processing is interrupted' do
      stager = Neutraliser::LocalStager.new(enabled: true, staging_dir: staging_dir)
      processor.instance_variable_set(:@stager, stager)
      allow(FFMPEG::Movie).to receive(:new).and_return(
        instance_double(FFMPEG::Movie, audio_stream: true)
      )
      allow(processor).to receive(:process_file_two_pass).and_raise(Interrupt)

      expect { processor.send(:process_file, video_file) }.to raise_error(Interrupt)
      expect(Dir.glob(File.join(staging_dir, '*'))).to be_empty
    end
  end

  describe 'object audio (Atmos / DTS:X)' do
    let(:video_file) { File.join(temp_dir, 'Show.S01E01.DDP5.1.Atmos.mkv') }
    let(:atmos_track) do
      { index: 0, codec: 'eac3', profile: 'Dolby Digital Plus + Dolby Atmos', channels: 6, bit_rate: 768_000,
        sample_rate: 48_000 }
    end
    let(:skip_decider) { instance_double(Neutraliser::SkipDecider, already_processed?: false) }
    let(:measured) do
      Neutraliser::Measurement.new(input_i: -26.0, input_tp: -12.0, input_lra: 8.0, input_thresh: -36.0,
                                   target_offset: 0.0)
    end

    before do
      File.write(video_file, 'x')
      allow(FFMPEG::Movie).to receive(:new).and_return(instance_double(FFMPEG::Movie, audio_stream: true))
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([atmos_track])
      allow(skip_decider).to receive(:mark_processed)
    end

    def run(processor)
      processor.instance_variable_set(:@skip_decider, skip_decider)
      result = nil
      output = capture_stdout { result = processor.send(:process_file, video_file) }
      [result, output]
    end

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    it 'skips by default, before measuring, and leaves the sidecar unstamped' do
      processor = described_class.new
      expect(processor).not_to receive(:analyze_loudness_for_path)

      result, output = run(processor)

      expect(result).to include(status: :skipped, reason: :object_audio, message: 'Dolby Digital Plus + Dolby Atmos')
      expect(output).to match(/Object audio \(Dolby Digital Plus \+ Dolby Atmos\).*skipping.*--allow-object-audio-loss/)
      expect(skip_decider).not_to have_received(:mark_processed)
    end

    it 'skips in a dry run too, so the preview shows what a real run will do' do
      result, = run(described_class.new(dry_run: true))

      expect(result[:reason]).to eq(:object_audio)
    end

    it 'processes with an explicit warning under --allow-object-audio-loss, reusing the probed tracks' do
      processor = described_class.new(allow_object_audio_loss: true)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      expect(processor).to receive(:normalize_file_with_paths)
        .with(video_file, video_file, measured, [atmos_track]).and_return({ normalization_type: 'Linear' })

      result, output = run(processor)

      expect(result).to include(status: :done, reason: :normalized)
      expect(output).to match(/Warning: primary track is Dolby Digital Plus \+ Dolby Atmos; re-encoding drops/)
    end

    it 'processes a file whose name says Atmos when neither probe finds it, with a note' do
      allow(Neutraliser::FFmpegWrapper).to receive_messages(
        detect_audio_tracks: [atmos_track.merge(profile: nil)], probe_audio_profile_mid_file: nil
      )
      processor = described_class.new
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      allow(processor).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Linear' })

      result, output = run(processor)

      expect(result[:status]).to eq(:done)
      expect(output).to match(/name suggests object audio but ffprobe found none/)
    end

    it 'records the source profile in the codec-decision log line' do
      expect(Neutraliser.logger).to receive(:log).with('  Audio: truehd (Dolby TrueHD + Dolby Atmos) -> flac (lossless)')
      allow(Neutraliser.logger).to receive(:log)

      described_class.new.send(:log_codec_decision, encoder: 'flac', source_codec: 'truehd',
                                                    source_profile: 'Dolby TrueHD + Dolby Atmos', lossless_output: true)
    end
  end

  describe 'object audio in the run manifest' do
    let(:video) { File.join(temp_dir, 'atmos.mkv') }
    let(:manifest_path) { File.join(temp_dir, '.neutraliser-run-manifest.jsonl') }

    before do
      File.write(video, 'x')
      File.write(manifest_path, "#{JSON.generate(file: File.expand_path(video), status: 'skipped',
                                                 reason: 'object_audio')}\n")
    end

    it 'records the skip reason' do
      processor = described_class.new
      allow(processor).to receive(:process_one).and_return(
        { file: File.expand_path(video), status: :skipped, reason: :object_audio, message: 'Dolby TrueHD + Dolby Atmos' }
      )

      processor.process(temp_dir)

      expect(JSON.parse(File.readlines(manifest_path).last)).to include('status' => 'skipped', 'reason' => 'object_audio')
    end

    it 'keeps an object-audio skip final on resume' do
      processor = described_class.new(resume: true)
      expect(processor).not_to receive(:process_one)

      expect(processor.process(temp_dir)[:resumed]).to eq(1)
    end

    it 'picks object-audio skips back up when resuming with --allow-object-audio-loss' do
      processor = described_class.new(resume: true, allow_object_audio_loss: true)
      expect(processor).to receive(:process_one).with(video)
                                                .and_return({ file: video, status: :done, reason: :normalized })

      expect(processor.process(temp_dir)[:resumed]).to eq(0)
    end
  end

  describe 'peak-limited skip (constant-gain path)' do
    let(:path) { File.join(temp_dir, 'a.mp4') }
    let(:profile_lufs) { Neutraliser::Profiles.get_profile('livingroom')[:lufs] }
    let(:tp) { Neutraliser::Profiles.get_profile('livingroom')[:tp] }

    def measurement(input_i:, input_tp:)
      Neutraliser::Measurement.new(input_i: input_i, input_tp: input_tp, input_lra: 5.0,
                                   input_thresh: -30.0, target_offset: 0.0)
    end

    before do
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks)
      File.write(path, 'x')
    end

    it 'skips a file already at its max safe gain' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 0.2)
      allow_any_instance_of(described_class).to receive(:analyze_loudness_for_path).and_return(m)
      proc = described_class.new(replace: false)
      expect(proc).not_to receive(:normalize_file_with_paths)

      result = proc.send(:process_file_two_pass, path, path, nil)

      expect(result).to include(status: :skipped, reason: :peak_limited)
    end

    it 'skips a quiet file whose peaks would turn it down (gain the wrong way)' do
      m = measurement(input_i: -28.0, input_tp: 0.5)
      proc = described_class.new(replace: false) # tolerance 1.0: |-2.0| used to pass the old check
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      expect(proc).not_to receive(:normalize_file_with_paths)

      expect(proc.send(:process_file_two_pass, path, path, nil)).to include(status: :skipped, reason: :peak_limited)
    end

    it 'uses --min-gain, not --tolerance, as the floor on a peak-capped gain' do
      m = measurement(input_i: -26.0, input_tp: -3.0) # +1.5 dB available, 6 LU off target
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks)

      strict = described_class.new(replace: false, tolerance: 2.0)
      allow(strict).to receive(:analyze_loudness_for_path).and_return(m)
      expect(strict.send(:process_file_two_pass, path, path, nil)).to include(reason: :peak_limited)

      lenient = described_class.new(replace: false, tolerance: 2.0, min_gain: 1.0)
      allow(lenient).to receive(:analyze_loudness_for_path).and_return(m)
      allow(lenient).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Linear' })
      expect(lenient.send(:process_file_two_pass, path, path, nil)).to include(status: :done, reason: :normalized)
    end

    it 'rejects --limit-db combined with dynamic normalisation' do
      expect { described_class.new(limit_db: 3.0, allow_dynamic: true) }
        .to raise_error(ArgumentError, /--limit-db/)
    end

    it 'lets --limit-db lift a file the plain peak cap would leave alone' do
      m = measurement(input_i: -26.0, input_tp: -2.0) # plain cap: +0.5 dB -> skipped
      plain = described_class.new(replace: false)
      allow(plain).to receive(:analyze_loudness_for_path).and_return(m)
      expect(plain.send(:process_file_two_pass, path, path, nil)).to include(reason: :peak_limited)

      limited = described_class.new(replace: false, limit_db: 4.0)
      allow(limited).to receive(:analyze_loudness_for_path).and_return(m)
      allow(limited).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Limited' })
      expect(limited.send(:process_file_two_pass, path, path, nil)).to include(status: :done, normalization_type: 'Limited')
    end

    it 'still processes a file with real achievable gain' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 5)
      proc = described_class.new(replace: false)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      allow(proc).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Linear' })

      result = proc.send(:process_file_two_pass, path, path, nil)

      expect(result).to include(status: :done, reason: :normalized)
    end

    it 'keeps the distance-to-target rule on the dynamic path' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 0.2)
      proc = described_class.new(replace: false, allow_dynamic: true)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      allow(proc).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Dynamic' })

      result = proc.send(:process_file_two_pass, path, path, nil)

      expect(result).to include(status: :done, reason: :normalized)
    end
  end

  describe 'prod-parity guards' do
    let(:video_file) { File.join(temp_dir, 'movie.mkv') }
    let(:dts_track) { { index: 0, channels: 6, codec: 'dts', bit_rate: 1_509_000, sample_rate: 48_000 } }
    let(:skip_decider) { instance_double(Neutraliser::SkipDecider, already_processed?: false, mark_processed: nil) }
    let(:measured) do
      Neutraliser::Measurement.new(input_i: -26.0, input_tp: -12.0, input_lra: 8.0, input_thresh: -36.0,
                                   target_offset: 0.0)
    end

    before do
      File.write(video_file, 'x')
      allow(FFMPEG::Movie).to receive(:new).and_return(instance_double(FFMPEG::Movie, audio_stream: true))
      allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([dts_track])
      allow(Neutraliser::FFmpegWrapper).to receive(:output_container) { |_in, out| File.extname(out).downcase }
      allow(Neutraliser::ObjectAudio).to receive(:detect).and_return(Neutraliser::ObjectAudio::Verdict.new(status: :none, profile: nil))
    end

    def run(processor)
      processor.instance_variable_set(:@skip_decider, skip_decider)
      processor.send(:process_file, video_file)
    end

    describe 'codec change' do
      it 'skips a DTS track before measuring, without stamping the sidecar' do
        processor = described_class.new
        expect(processor).not_to receive(:analyze_loudness_for_path)

        result = nil
        expect { result = run(processor) }.to output(/Codec change.*--allow-codec-change/).to_stdout

        expect(result).to include(status: :skipped, reason: :codec_change, message: 'dts would be re-encoded as flac')
        expect(skip_decider).not_to have_received(:mark_processed)
      end

      it 'processes it under --allow-codec-change' do
        processor = described_class.new(allow_codec_change: true)
        allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
        allow(processor).to receive(:normalize_file_with_paths).and_return({ normalization_type: 'Linear' })

        expect(run(processor)).to include(status: :done)
      end
    end

    describe 'disk guard' do
      let(:aac_track) { dts_track.merge(codec: 'aac') }

      before { allow(Neutraliser::FFmpegWrapper).to receive(:detect_audio_tracks).and_return([aac_track]) }

      def guarded(verdict)
        guard = Neutraliser::DiskGuard.new(min_free: 1)
        allow(guard).to receive(:verdict).and_return(verdict)
        described_class.new(disk_guard: guard)
      end

      it 'skips a file when space is short, before measuring' do
        processor = guarded(:skip)
        expect(processor).not_to receive(:analyze_loudness_for_path)

        expect(run(processor)).to include(status: :skipped, reason: :low_disk)
        expect(skip_decider).not_to have_received(:mark_processed)
      end

      it 'raises an abort for the run when space is critically low' do
        expect { run(guarded(:abort)) }.to raise_error(Neutraliser::DiskGuard::Abort)
      end

      it 'stops a directory run at the abort, keeping what was done and flagging it' do
        File.write(File.join(temp_dir, 'b.mkv'), 'x')
        processor = guarded(:ok)
        done = { file: video_file, status: :done, reason: :normalized }
        calls = 0
        allow(processor).to receive(:process_one) do
          calls += 1
          calls == 1 ? done : raise(Neutraliser::DiskGuard::Abort, 'low')
        end

        summary = processor.process(temp_dir)

        expect(summary).to include(aborted: true, done: 1)
      end

      it 'does nothing in a dry run' do
        guard = Neutraliser::DiskGuard.new(abort_free: 1)
        expect(guard).not_to receive(:verdict)
        processor = described_class.new(dry_run: true, disk_guard: guard)
        allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)

        expect(run(processor)).to include(status: :done, reason: :dry_run)
      end
    end

    describe 'output verification' do
      let(:aac_track) { dts_track.merge(codec: 'aac') }

      def render(processor, mismatch)
        allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
        allow(Neutraliser::FileManager).to receive(:output_mismatch).and_return(mismatch)
        processor.send(:render_normalization, video_file, video_file, [aac_track], log_message: 'x') do |_wp, out, _t|
          File.write(out, 'y')
          { encoder: 'aac' }
        end
      end

      it 'refuses to replace the original when the output does not match the source' do
        processor = described_class.new(replace: false)

        expect { render(processor, 'output is 3.0s long, source is 60.0s') }
          .to raise_error(Neutraliser::OutputVerificationError, /does not match the source: output is 3.0s long/)
        expect(Dir.children(temp_dir)).to eq(['movie.mkv'])
      end

      it 'passes the expected audio stream count, including a kept original' do
        processor = described_class.new(replace: false, keep_original_audio: true)
        render(processor, nil)

        expect(Neutraliser::FileManager).to have_received(:output_mismatch)
          .with(video_file, anything, expected_audio_streams: 2)
      end
    end
  end
end
