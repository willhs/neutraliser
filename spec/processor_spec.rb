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

      expect(profile).to include(name: 'custom-18.3', lufs: -18.3, tp: -1.5, lra: 12.0)
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
        Neutraliser::FileResult.done(video_1, :normalized)
      )
      expect(processor).to receive(:process_one).with(video_2).and_return(
        Neutraliser::FileResult.skipped(video_2, :within_tolerance)
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
                                      status: 'done',
                                      reason: 'normalized',
                                      profile: 'livingroom',
                                      target_lufs: -20.0,
                                      replace: false
                                    }))
      end

      expect(processor).to receive(:process_one).with(pending).and_return(
        Neutraliser::FileResult.done(pending, :normalized)
      )
      expect(processor).not_to receive(:process_one).with(completed)

      summary = processor.process(temp_dir)
      expect(summary[:resumed]).to eq(1)
      expect(summary[:queued]).to eq(1)
      expect(summary[:done]).to eq(1)
      expect(summary[:failed]).to eq(0)
    end

    context 'when a run is cut off part-way (Ctrl-C, SIGTERM, crash)' do
      let(:first) { File.join(temp_dir, 'a.mp4') }
      let(:second) { File.join(temp_dir, 'b.mp4') }
      let(:third) { File.join(temp_dir, 'c.mp4') }
      let(:manifest) { File.join(temp_dir, '.neutraliser-run-manifest.jsonl') }

      def entries = File.readlines(manifest).map { |line| JSON.parse(line) }

      before do
        [first, second, third].each { |f| File.write(f, 'x') }
        allow(processor_under_test).to receive(:process_one).with(first).and_return(
          Neutraliser::FileResult.done(first, :normalized)
        )
        allow(processor_under_test).to receive(:process_one).with(second).and_raise(Interrupt)
      end

      let(:processor_under_test) { described_class.new }

      it 'has already recorded the files that finished, not only "queued"' do
        expect { processor_under_test.process(temp_dir) }.to raise_error(Interrupt)

        finished = entries.select { |e| e['status'] == 'done' }
        expect(finished.map { |e| e['file'] }).to eq([File.expand_path(first)])
        expect(entries.count { |e| e['status'] == 'queued' }).to eq(3)
      end

      it 'lets --resume skip the finished file and retry the rest' do
        expect { processor_under_test.process(temp_dir) }.to raise_error(Interrupt)

        resumed = described_class.new(resume: true)
        expect(resumed).not_to receive(:process_one).with(first)
        expect(resumed).to receive(:process_one).with(second).and_return(Neutraliser::FileResult.done(second, :normalized))
        expect(resumed).to receive(:process_one).with(third).and_return(Neutraliser::FileResult.done(third, :normalized))

        summary = resumed.process(temp_dir)
        expect(summary[:resumed]).to eq(1)
        expect(summary[:done]).to eq(2)
      end
    end

    it 'records the mode per file in the run manifest, spelt as ever' do
      modes = { 'a.mp4' => Neutraliser::Mode::LINEAR, 'b.mp4' => Neutraliser::Mode::DYNAMIC,
                'c.mp4' => Neutraliser::Mode::LIMITED, 'd.mp4' => Neutraliser::Mode::COMPRESSED }
      processor = described_class.new
      videos = modes.keys.to_h { |name| [name, File.join(temp_dir, name)] }
      videos.each_value { |video| File.write(video, 'x') }
      allow(processor).to receive(:process_one) do |video|
        Neutraliser::FileResult.done(video, :normalized, mode: modes.fetch(File.basename(video)))
      end

      summary = nil
      expect { summary = processor.process(temp_dir) }.to output.to_stdout
      done = File.readlines(summary[:manifest_path]).map { |line| JSON.parse(line) }.select { |entry| entry['status'] == 'done' }

      expect(done.to_h { |entry| [File.basename(entry['file']), entry['normalization_type']] })
        .to eq('a.mp4' => 'Linear', 'b.mp4' => 'Dynamic', 'c.mp4' => 'Limited', 'd.mp4' => 'Compressed')
      expect(summary).to include(linear: 1, dynamic: 1, limited: 1, compressed: 1)
    end

    it 'resumes from a manifest an older version wrote, taking only the final reasons as done' do
      processor = described_class.new(resume: true)
      files = %w[normalized already_processed no_audio_track unsupported_format dry_run low_disk timeout object_audio]
              .to_h { |reason| [reason, File.join(temp_dir, "#{reason}.mp4")] }
      files.each_value { |file| File.write(file, 'x') }
      profile = processor.profile
      File.write(File.join(temp_dir, '.neutraliser-run-manifest.jsonl'), files.map do |reason, file|
        JSON.generate(file: file, status: 'done', reason: reason, profile: profile[:name], target_lufs: profile[:lufs], replace: false)
      end.join("\n"))
      allow(processor).to receive(:process_one) { |file| Neutraliser::FileResult.done(file, :normalized) }

      summary = processor.process(temp_dir)

      expect(summary[:resumed]).to eq(4)
      expect(summary[:results].map { |result| File.basename(result.file, '.mp4') })
        .to contain_exactly('dry_run', 'low_disk', 'timeout', 'object_audio')
    end
  end

  describe '#process_file' do
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'video')
      stub_probe(audio: [ProbeFixture.audio(codec: 'aac', bit_rate: '256000')])
    end

    it 'skips unsupported file extensions' do
      txt = File.join(temp_dir, 'note.txt')
      File.write(txt, 'x')

      expect { described_class.new.send(:process_file, txt) }
        .to output(/not a supported video format/).to_stdout
    end

    it 'skips files with no audio stream' do
      processor = described_class.new
      stub_probe(audio: [])

      expect { processor.send(:process_file, video_file) }
        .to output(/No audio track found, skipping/).to_stdout
    end

    it 'fails a file ffprobe cannot read as :unreadable, with one probe and no analysis' do
      stub_unreadable_probe
      processor = described_class.new
      expect(processor).not_to receive(:analyze_loudness_for_path)

      result = nil
      expect { result = processor.send(:process_file, video_file) }.to output(/Unreadable: ffprobe could not read this file/).to_stdout

      expect(result).to have_attributes(status: :failed, reason: :unreadable)
      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once
    end

    it 'lets a probe that hangs end the file as a retryable :timeout, not an unreadable one' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Neutraliser::FFmpegTimeoutError, 'File probe timed out')

      result = nil
      expect { result = described_class.new.send(:process_file, video_file) }.to output(/Timed out/).to_stdout

      expect(result).to have_attributes(status: :failed, reason: :timeout)
    end

    it 'asks ffprobe about a file once, however many checks and passes read its facts' do
      processor = described_class.new(dry_run: true)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(Neutraliser::Measurement.already_at_target(processor.instance_variable_get(:@profile)))

      expect { processor.send(:process_file, video_file) }.to output.to_stdout

      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once
    end

    it 'prints dry-run output using numeric conversion for measured input' do
      processor = described_class.new(dry_run: true)
      measured = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-18.0',
        'input_tp' => '-2.0',
        'input_lra' => '8.0',
        'input_thresh' => '-28.0',
        'target_offset' => '2.0'
      )

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
      measured = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-40.0',
        'input_tp' => '-12.0',
        'input_lra' => '8.0',
        'input_thresh' => '-50.0',
        'target_offset' => '0.0'
      )
      skip_decider = instance_double(Neutraliser::SkipDecider, already_processed?: false)

      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      processor.instance_variable_set(:@skip_decider, skip_decider)

      expect(skip_decider).not_to receive(:mark_processed)

      result = nil
      expect { result = processor.send(:process_file, video_file) }.to output(/DRY RUN/).to_stdout
      expect(result.reason).to eq(:dry_run)
    end

    it 'handles analysis errors by reporting and continuing' do
      processor = described_class.new
      allow(processor).to receive(:analyze_loudness_for_path).and_raise(StandardError, 'analysis failed')

      expect { processor.send(:process_file, video_file) }
        .to output(/Error processing file: analysis failed/).to_stdout
    end

    it 'records a distinct :timeout reason for FFmpegTimeoutError, not the generic processing_error bucket' do
      processor = described_class.new
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      result = nil
      expect { result = processor.send(:process_file, video_file) }
        .to output(/Timed out processing file: timed out/).to_stdout

      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:timeout)
    end

    it 'records a distinct :output_verification_failed reason, not the generic processing_error bucket' do
      processor = described_class.new
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::OutputVerificationError, 'Output file verification failed - processing aborted')

      result = nil
      expect { result = processor.send(:process_file, video_file) }
        .to output(/Output verification failed/).to_stdout

      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:output_verification_failed)
    end

    it 'records a distinct :ffmpeg_error reason for a non-timeout FFmpegError' do
      processor = described_class.new
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegError, 'corrupt container')

      result = processor.send(:process_file, video_file)

      expect(result.status).to eq(:failed)
      expect(result.reason).to eq(:ffmpeg_error)
    end
  end

  describe 'preflight checks' do
    let(:show_dir) { File.join(temp_dir, 'The Simpsons') }
    let(:episodes) { %w[s01e01.mkv s01e02.mkv].map { |name| File.join(show_dir, name) } }

    before do
      FileUtils.mkdir_p(show_dir)
      episodes.each { |episode| File.write(episode, 'x') }
      stub_probe
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_return(nil)
    end

    after { FileUtils.chmod(0o755, show_dir) }

    it 'fails every file in a folder it cannot write to as :not_writable, before any analysis', :needs_permissions do
      FileUtils.chmod(0o555, show_dir)
      processor = described_class.new(replace: true)
      expect(processor).not_to receive(:analyze_loudness_for_path)

      summary = nil
      expect { summary = processor.process(show_dir) }
        .to output(/Not writable — fix permissions on 1 folder\(s\):\n.*The Simpsons/).to_stdout

      expect(summary[:results].map(&:reason)).to eq(%i[not_writable not_writable])
      expect(summary[:results].first.message).to eq("can't write to #{File.expand_path(show_dir)} (Permission denied); fix the folder's permissions")
      expect(summary[:failed_by_reason]).to eq(not_writable: 2)
      expect(summary[:not_writable_dirs]).to eq([File.expand_path(show_dir)])
      expect(Dir.children(show_dir).grep(/write-check/)).to be_empty
    end

    it 'fails a file whose subtitles ffmpeg cannot copy as :unsupported_subtitle, before any analysis' do
      stub_probe(subtitles: [nil], stderr: ProbeFixture.unknown_subtitle_stderr('S_TEXT/WEBVTT'))
      processor = described_class.new
      expect(processor).not_to receive(:analyze_loudness_for_path)

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }
        .to output(/Unsupported subtitle: subtitle stream 2 \(S_TEXT\/WEBVTT\)/).to_stdout

      expect(result).to have_attributes(status: :failed, reason: :unsupported_subtitle)
      expect(result.message).to start_with("subtitle stream 2 (S_TEXT/WEBVTT) can't be copied")
    end

    it 'takes the failure reason an FFmpegError recognised from the encode' do
      processor = described_class.new
      allow(Neutraliser::ObjectAudio).to receive(:detect).and_return(Neutraliser::ObjectAudio::NONE)
      allow(processor).to receive(:analyze_loudness_for_path)
        .and_raise(Neutraliser::FFmpegError.new('Normalization failed (exit 1): Subtitle codec 0 is not supported.',
                                                reason: :unsupported_subtitle))

      result = nil
      expect { result = processor.send(:process_file, episodes.first) }.to output.to_stdout

      expect(result).to have_attributes(status: :failed, reason: :unsupported_subtitle,
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

    let(:working) { ProbeFixture.source('/working/movie.mp4') }

    it 'delegates to AudioAnalyser#analyze with the staged copy, caching under the original path' do
      measurement = Neutraliser::Measurement.already_at_target(profile)
      expect(analyser).to receive(:analyze)
        .with(working, cached_as: '/orig/movie.mp4', profile: profile, tolerance: 1.0)
        .and_return(measurement)

      result = processor.send(:analyze_loudness_for_path, working, '/orig/movie.mp4')

      expect(result).to eq(measurement)
    end

    it 'raises ffmpeg errors from measurement instead of using fake fallback data' do
      allow(analyser).to receive(:analyze).and_raise(Neutraliser::FFmpegError, 'boom')

      expect { processor.send(:analyze_loudness_for_path, working, '/tmp/movie.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

  describe '#normalize_file_with_paths' do
    let(:processor) { described_class.new(replace: false) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }
    let(:output_file) { File.join(temp_dir, 'movie_normalized.mp4') }
    let(:working) { ProbeFixture.source(video_file, audio: [ProbeFixture.audio(codec: 'aac', bit_rate: '256000')]) }
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
      stub_probe(audio: [ProbeFixture.audio(codec: 'aac', bit_rate: '256000')])
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization) do |_source, output, *_rest, **_kwargs|
        File.write(output, 'y')
        { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false }
      end
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
    end

    it 'writes to _normalized output in copy mode' do
      processor.send(:normalize_file_with_paths, video_file, working, measured_data)

      expect(File.read(output_file)).to eq('y')
      expect(File.read(video_file)).to eq('x')
    end

    it 'raises a distinct OutputVerificationError when output fails integrity checks' do
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(false)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(output_file).and_return(true)
      allow(FileUtils).to receive(:rm_f)

      expect { processor.send(:normalize_file_with_paths, video_file, working, measured_data) }
        .to raise_error(Neutraliser::OutputVerificationError, /Output file verification failed/)
    end

    it 'returns the codec decision including normalization_type' do
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization) do |_source, output, *_rest, **_kwargs|
        File.write(output, 'y')
        { encoder: 'aac', bitrate: 256_000, source_codec: 'aac', source_bitrate: 256_000, lossless_output: false, mode: Neutraliser::Mode::DYNAMIC }
      end

      result = processor.send(:normalize_file_with_paths, video_file, working, measured_data)

      expect(result[:mode]).to eq(Neutraliser::Mode::DYNAMIC)
    end

    it 'passes allow_dynamic through to FFmpegWrapper' do
      linear_processor = described_class.new(replace: false, allow_dynamic: true)
      File.write(video_file, 'x')
      allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)

      linear_processor.send(:normalize_file_with_paths, video_file, working, measured_data)

      expect(Neutraliser::FFmpegWrapper).to have_received(:apply_normalization)
        .with(working, anything, measured_data, anything, hash_including(allow_dynamic: true))
    end

    it 'cleans up the temp output file even when interrupted (not just on StandardError)' do
      allow(processor).to receive(:commit_output).and_raise(Interrupt)

      expect { processor.send(:normalize_file_with_paths, video_file, working, measured_data) }
        .to raise_error(Interrupt)

      expect(File.exist?(output_file)).to be(false)
    end

    it 'does not delete the output file once commit_output has already succeeded' do
      # Simulate the real artifact commit_output would produce/leave in place
      # (in copy mode, output_path *is* the final deliverable - the ensure
      # cleanup must not remove it just because it still exists on disk).
      File.write(output_file, 'normalized content')
      allow(processor).to receive(:commit_output)

      processor.send(:normalize_file_with_paths, video_file, working, measured_data)

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
        Neutraliser::FileResult.done('a.mkv', :normalized, mode: Neutraliser::Mode::LINEAR),
        Neutraliser::FileResult.done('b.mkv', :normalized, mode: Neutraliser::Mode::LINEAR),
        Neutraliser::FileResult.done('c.mkv', :normalized, mode: Neutraliser::Mode::DYNAMIC),
        Neutraliser::FileResult.skipped('d.mkv', :within_tolerance)
      ]

      summary = processor.send(:summarize_results, found: 4, queued: 4, resumed: 0, manifest_path: nil, results: results)

      expect(summary).to include(linear: 2, dynamic: 1)
    end

    it 'warns when a file went Dynamic' do
      expect(Neutraliser.logger).to receive(:log).with(/Warning: file went Dynamic/).at_least(:once)
      allow(Neutraliser.logger).to receive(:log)

      processor.send(:log_codec_decision, encoder: 'aac', bitrate: 128_000, mode: Neutraliser::Mode::DYNAMIC)
    end

    it 'logs the shortfall when the gain was peak-capped' do
      expect(Neutraliser.logger).to receive(:log).with(/Peak-capped: landed 8.5 LU short of -20.0 LUFS/)
      allow(Neutraliser.logger).to receive(:log)

      processor.send(:log_codec_decision, encoder: 'aac', bitrate: 128_000, mode: Neutraliser::Mode::LINEAR, shortfall_lu: 8.5)
    end
  end

  describe '#process_file with fast mode' do
    let(:processor) { described_class.new(fast: true, allow_dynamic: true, dry_run: true) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'x')
      stub_probe(audio: [ProbeFixture.audio(codec: 'aac', bit_rate: '256000')])
    end

    it 'uses fast single-pass in dry-run mode' do
      result = processor.send(:process_file, video_file)

      expect(result.status).to eq(:done)
      expect(result.reason).to eq(:dry_run)
    end
  end

  describe '#process_file with local staging' do
    let(:staging_dir) { Dir.mktmpdir }
    let(:processor) { described_class.new(local_stage: true, dry_run: true) }
    let(:video_file) { File.join(temp_dir, 'movie.mp4') }

    before do
      File.write(video_file, 'video content')
      stub_probe(audio: [ProbeFixture.audio(codec: 'aac', bit_rate: '256000')])
    end

    after do
      FileUtils.remove_entry(staging_dir) if Dir.exist?(staging_dir)
    end

    it 'stages file locally before processing' do
      allow(processor).to receive(:process_file_two_pass).and_return(
        Neutraliser::FileResult.done(video_file, :dry_run)
      )

      result = processor.send(:process_file, video_file)

      expect(result.status).to eq(:done)
    end

    it 'cleans up staged file after processing' do
      allow(processor).to receive(:process_file_two_pass).and_return(
        Neutraliser::FileResult.done(video_file, :dry_run)
      )

      processor.send(:process_file, video_file)

      stager = processor.instance_variable_get(:@stager)
      staged_files = Dir.glob(File.join(stager.instance_variable_get(:@staging_dir), '*'))
      expect(staged_files).to be_empty
    end

    it 'cleans up the staged input when processing is interrupted' do
      stager = Neutraliser::LocalStager.new(enabled: true, staging_dir: staging_dir)
      processor.instance_variable_set(:@stager, stager)
      allow(processor).to receive(:process_file_two_pass).and_raise(Interrupt)

      expect { processor.send(:process_file, video_file) }.to raise_error(Interrupt)
      expect(Dir.glob(File.join(staging_dir, '*'))).to be_empty
    end
  end

  describe 'object audio (Atmos / DTS:X)' do
    let(:video_file) { File.join(temp_dir, 'Show.S01E01.DDP5.1.Atmos.mkv') }
    let(:atmos_track) do
      ProbeFixture.audio(codec: 'eac3', profile: 'Dolby Digital Plus + Dolby Atmos', channels: 6, bit_rate: '768000')
    end
    let(:skip_decider) { instance_double(Neutraliser::SkipDecider, already_processed?: false) }
    let(:measured) do
      Neutraliser::Measurement.new(input_i: -26.0, input_tp: -12.0, input_lra: 8.0, input_thresh: -36.0,
                                   target_offset: 0.0)
    end

    before do
      File.write(video_file, 'x')
      stub_probe(audio: [atmos_track])
      allow(skip_decider).to receive(:mark_processed)
      allow(skip_decider).to receive(:mark_left)
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

      expect(result).to have_attributes(status: :skipped, reason: :object_audio, message: 'Dolby Digital Plus + Dolby Atmos')
      expect(output).to match(/Object audio \(Dolby Digital Plus \+ Dolby Atmos\).*skipping.*--allow-object-audio-loss/)
      expect(skip_decider).not_to have_received(:mark_processed)
      expect(skip_decider).to have_received(:mark_left)
        .with(video_file, have_attributes(reason: 'object_audio', message: 'Dolby Digital Plus + Dolby Atmos'))
    end

    it 'skips in a dry run too, so the preview shows what a real run will do' do
      result, = run(described_class.new(dry_run: true))

      expect(result.reason).to eq(:object_audio)
    end

    it 'processes with an explicit warning under --allow-object-audio-loss, on the one probe it already made' do
      processor = described_class.new(allow_object_audio_loss: true)
      allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
      expect(processor).to receive(:normalize_file_with_paths)
        .with(video_file, an_instance_of(Neutraliser::Source), measured).and_return({ mode: Neutraliser::Mode::LINEAR })

      result, output = run(processor)

      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once

      expect(result).to have_attributes(status: :done, reason: :normalized)
      expect(output).to match(/Warning: primary track is Dolby Digital Plus \+ Dolby Atmos; re-encoding drops/)
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
        Neutraliser::FileResult.skipped(File.expand_path(video), :object_audio, message: 'Dolby TrueHD + Dolby Atmos')
      )

      processor.process(temp_dir)

      expect(JSON.parse(File.readlines(manifest_path).last)).to include('status' => 'skipped', 'reason' => 'object_audio')
    end

    it 'looks at an object-audio skip again on resume, since ffmpeg may have changed' do
      processor = described_class.new(resume: true)
      expect(processor).to receive(:process_one).with(video)
                                                .and_return(Neutraliser::FileResult.skipped(video, :object_audio))

      expect(processor.process(temp_dir)[:resumed]).to eq(0)
    end

    it 'picks object-audio skips back up when resuming with --allow-object-audio-loss' do
      processor = described_class.new(resume: true, allow_object_audio_loss: true)
      expect(processor).to receive(:process_one).with(video)
                                                .and_return(Neutraliser::FileResult.done(video, :normalized))

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

    let(:working) { ProbeFixture.source(path) }

    before { File.write(path, 'x') }

    it 'skips a file already at its max safe gain' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 0.2)
      allow_any_instance_of(described_class).to receive(:analyze_loudness_for_path).and_return(m)
      proc = described_class.new(replace: false)
      expect(proc).not_to receive(:normalize_file_with_paths)

      result = proc.send(:process_file_two_pass, path, working)

      expect(result).to have_attributes(status: :skipped, reason: :peak_limited)
    end

    it 'labels a -24 LUFS / 0 dBTP file peak_limited under --tolerance 2 --min-gain 1, not within_tolerance' do
      m = measurement(input_i: -23.98, input_tp: 0.03)
      proc = described_class.new(replace: false, dry_run: true, tolerance: 2.0, min_gain: 1.0)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)

      expect(proc.send(:process_file_two_pass, path, working)).to have_attributes(status: :skipped, reason: :peak_limited)
    end

    it 'names the measured level when a file really is within tolerance' do
      m = measurement(input_i: profile_lufs - 1.5, input_tp: -6.0)
      proc = described_class.new(replace: false, tolerance: 2.0)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)

      expect { expect(proc.send(:process_file_two_pass, path, working)).to have_attributes(reason: :within_tolerance) }
        .to output(/Already at target level \(-21\.5 LUFS, within 2\.0 LU of -20\.0\)/).to_stdout
    end

    it 'skips a quiet file whose peaks would turn it down (gain the wrong way)' do
      m = measurement(input_i: -28.0, input_tp: 0.5)
      proc = described_class.new(replace: false) # tolerance 1.0: |-2.0| used to pass the old check
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      expect(proc).not_to receive(:normalize_file_with_paths)

      expect(proc.send(:process_file_two_pass, path, working)).to have_attributes(status: :skipped, reason: :peak_limited)
    end

    it 'uses --min-gain, not --tolerance, as the floor on a peak-capped gain' do
      m = measurement(input_i: -26.0, input_tp: -3.0) # +1.5 dB available, 6 LU off target
      strict = described_class.new(replace: false, tolerance: 2.0)
      allow(strict).to receive(:analyze_loudness_for_path).and_return(m)
      expect(strict.send(:process_file_two_pass, path, working)).to have_attributes(reason: :peak_limited)

      lenient = described_class.new(replace: false, tolerance: 2.0, min_gain: 1.0)
      allow(lenient).to receive(:analyze_loudness_for_path).and_return(m)
      allow(lenient).to receive(:normalize_file_with_paths).and_return({ mode: Neutraliser::Mode::LINEAR })
      expect(lenient.send(:process_file_two_pass, path, working)).to have_attributes(status: :done, reason: :normalized)
    end

    it 'rejects --limit-db combined with dynamic normalisation' do
      expect { described_class.new(limit_db: 3.0, allow_dynamic: true) }
        .to raise_error(ArgumentError, /--limit-db/)
    end

    it 'refuses --limit-db on an ffmpeg whose limiter has no latency option' do
      allow(Neutraliser::FFmpegWrapper).to receive(:version).and_return([4, 2])

      expect { described_class.new(limit_db: 3.0) }.to raise_error(ArgumentError, /--limit-db needs ffmpeg 5\.1/)
      expect { described_class.new }.not_to raise_error
    end

    it 'lets --limit-db lift a file the plain peak cap would leave alone' do
      m = measurement(input_i: -26.0, input_tp: -2.0) # plain cap: +0.5 dB -> skipped
      plain = described_class.new(replace: false)
      allow(plain).to receive(:analyze_loudness_for_path).and_return(m)
      expect(plain.send(:process_file_two_pass, path, working)).to have_attributes(reason: :peak_limited)

      limited = described_class.new(replace: false, limit_db: 4.0)
      allow(limited).to receive(:analyze_loudness_for_path).and_return(m)
      allow(limited).to receive(:normalize_file_with_paths).and_return({ mode: Neutraliser::Mode::LIMITED })
      expect(limited.send(:process_file_two_pass, path, working)).to have_attributes(status: :done, mode: Neutraliser::Mode::LIMITED)
    end

    it 'still processes a file with real achievable gain' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 5)
      proc = described_class.new(replace: false)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      allow(proc).to receive(:normalize_file_with_paths).and_return({ mode: Neutraliser::Mode::LINEAR })

      result = proc.send(:process_file_two_pass, path, working)

      expect(result).to have_attributes(status: :done, reason: :normalized)
    end

    it 'keeps the distance-to-target rule on the dynamic path' do
      m = measurement(input_i: profile_lufs - 6, input_tp: tp - 0.2)
      proc = described_class.new(replace: false, allow_dynamic: true)
      allow(proc).to receive(:analyze_loudness_for_path).and_return(m)
      allow(proc).to receive(:normalize_file_with_paths).and_return({ mode: Neutraliser::Mode::DYNAMIC })

      result = proc.send(:process_file_two_pass, path, working)

      expect(result).to have_attributes(status: :done, reason: :normalized)
    end
  end

  describe 'prod-parity guards' do
    let(:video_file) { File.join(temp_dir, 'movie.mkv') }
    let(:dts_track) { ProbeFixture.audio(codec: 'dts', channels: 6, bit_rate: '1509000') }
    let(:skip_decider) do
      instance_double(Neutraliser::SkipDecider, already_processed?: false, mark_processed: nil, mark_left: nil)
    end
    let(:measured) do
      Neutraliser::Measurement.new(input_i: -26.0, input_tp: -12.0, input_lra: 8.0, input_thresh: -36.0,
                                   target_offset: 0.0)
    end

    before do
      File.write(video_file, 'x')
      stub_probe(audio: [dts_track])
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

        expect(result).to have_attributes(status: :skipped, reason: :codec_change, message: 'dts would be re-encoded as flac')
        expect(skip_decider).not_to have_received(:mark_processed)
        expect(skip_decider).to have_received(:mark_left)
          .with(video_file, have_attributes(reason: 'codec_change', message: 'dts would be re-encoded as flac'))
      end

      it 'processes it under --allow-codec-change' do
        processor = described_class.new(allow_codec_change: true)
        allow(processor).to receive(:analyze_loudness_for_path).and_return(measured)
        allow(processor).to receive(:normalize_file_with_paths).and_return({ mode: Neutraliser::Mode::LINEAR })

        expect(run(processor)).to have_attributes(status: :done)
      end
    end

    describe 'disk guard' do
      before { stub_probe(audio: [ProbeFixture.audio(codec: 'aac', channels: 6, bit_rate: '1509000')]) }

      def guarded(verdict)
        guard = Neutraliser::DiskGuard.new(min_free: 1)
        allow(guard).to receive(:verdict).and_return(verdict)
        described_class.new(disk_guard: guard)
      end

      it 'skips a file when space is short, before measuring' do
        processor = guarded(:skip)
        expect(processor).not_to receive(:analyze_loudness_for_path)

        expect(run(processor)).to have_attributes(status: :skipped, reason: :low_disk)
        expect(skip_decider).not_to have_received(:mark_processed)
      end

      it 'raises an abort for the run when space is critically low' do
        expect { run(guarded(:abort)) }.to raise_error(Neutraliser::DiskGuard::Abort)
      end

      it 'stops a directory run at the abort, keeping what was done and flagging it' do
        File.write(File.join(temp_dir, 'b.mkv'), 'x')
        processor = guarded(:ok)
        done = Neutraliser::FileResult.done(video_file, :normalized)
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

        expect(run(processor)).to have_attributes(status: :done, reason: :dry_run)
      end
    end

    describe 'output verification' do
      let(:working) { ProbeFixture.source(video_file, audio: [ProbeFixture.audio(codec: 'aac', channels: 6)]) }

      before { stub_probe }

      def render(processor, mismatch)
        allow(Neutraliser::FileManager).to receive(:verify_file_integrity).and_return(true)
        allow(Neutraliser::FileManager).to receive(:output_mismatch).and_return(mismatch)
        processor.send(:render_normalization, video_file, working, log_message: 'x') do |out|
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
          .with(working, an_instance_of(Neutraliser::Source), hash_including(layout: an_object_having_attributes(size: 2)))
      end
    end
  end
end
