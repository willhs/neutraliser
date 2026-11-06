require 'spec_helper'
require 'fileutils'
require 'open3'
require_relative 'support/lra_fixture'

# --lra-target / --centre-boost: opt-in compression. Off by default; the default
# path's behaviour is pinned by the rest of the suite.
RSpec.describe 'Opt-in compression (--lra-target)' do
  let(:ok_status) { instance_double(Process::Status, success?: true) }
  let(:profile) { Neutraliser::Profiles::LIVING_ROOM.merge(name: 'livingroom') }

  def measurement(lra:, input_i: -22.0, input_tp: -8.0)
    Neutraliser::Measurement.new(input_i: input_i, input_tp: input_tp, input_lra: lra, input_thresh: -32.0, target_offset: 0.0)
  end

  describe 'Processor.new' do
    it 'is off by default' do
      expect(Neutraliser::Processor.new.instance_variable_get(:@lra_target)).to be_nil
    end

    it 'accepts a target, with or without a centre boost' do
      expect { Neutraliser::Processor.new(lra_target: 10) }.not_to raise_error
      expect { Neutraliser::Processor.new(lra_target: 10, centre_boost: 4) }.not_to raise_error
      expect { Neutraliser::Processor.new(lra_target: 10, limit_db: 3) }.not_to raise_error if Neutraliser::FFmpegWrapper.wide_filter_options?
    end

    it 'refuses the options that already decide the dynamics another way' do
      [{ allow_dynamic: true }, { profile: 'night' }, { fast_verify: true },
       { fast: true, allow_dynamic: true }].each do |conflict|
        expect { Neutraliser::Processor.new(lra_target: 10, **conflict) }
          .to raise_error(ArgumentError, /--lra-target.*cannot combine/), "expected #{conflict} to be refused"
      end
    end

    it 'refuses a centre boost with no target, and out-of-range values' do
      expect { Neutraliser::Processor.new(centre_boost: 4) }.to raise_error(ArgumentError, /--centre-boost.*--lra-target/)
      expect { Neutraliser::Processor.new(lra_target: 10, centre_boost: 0) }.to raise_error(ArgumentError, /between 0 and 12/)
      expect { Neutraliser::Processor.new(lra_target: 10, centre_boost: -3) }.to raise_error(ArgumentError, /between 0 and 12/)
      expect { Neutraliser::Processor.new(lra_target: 10, centre_boost: 13) }.to raise_error(ArgumentError, /between 0 and 12/)
      expect { Neutraliser::Processor.new(lra_target: 0) }.to raise_error(ArgumentError, /greater than 0/)
      expect { Neutraliser::Processor.new(lra_target: -4) }.to raise_error(ArgumentError, /greater than 0/)
    end
  end

  describe 'CLI' do
    it 'passes the options to Processor and prints the compressed count' do
      processor = instance_double(Neutraliser::Processor,
                                  process: { found: 1, queued: 1, resumed: 0, done: 1, skipped: 0, failed: 0, linear: 0, dynamic: 0, limited: 0,
                                             compressed: 1 })
      seen = nil
      allow(Neutraliser::Processor).to receive(:new) do |**kwargs|
        seen = kwargs
        processor
      end

      expect do
        Neutraliser::CLI.start(['process', '--lra-target', '9', '--centre-boost', '3.5', '/tmp/library'])
      end.to output(/limited=0, compressed=1/).to_stdout
      expect(seen).to include(lra_target: 9, centre_boost: 3.5)
    end

    it 'turns a refused combination into a one-line error' do
      expect { Neutraliser::CLI.start(['process', '--lra-target', '9', '--allow-dynamic', '/tmp/library']) }
        .to raise_error(SystemExit).and output(/Error: --lra-target.*cannot combine/).to_stderr
    end

    it 'leaves the summary line as it was when nothing was compressed' do
      allow(Neutraliser::Processor).to receive(:new).and_return(
        instance_double(Neutraliser::Processor,
                        process: { found: 1, queued: 1, resumed: 0, done: 1, skipped: 0, failed: 0, linear: 1, dynamic: 0, limited: 0, compressed: 0 })
      )

      expect { Neutraliser::CLI.start(['process', '/tmp/library']) }.to output(/limited=0\n/).to_stdout
    end
  end

  describe 'Processor#process_file_compressed (dry run)' do
    let(:processor) { Neutraliser::Processor.new(lra_target: 10, dry_run: true) }
    let(:film) { ProbeFixture.source('/m/film.mkv', audio: [ProbeFixture.audio(codec: 'ac3', channels: 6, layout: '5.1')]) }

    it 'plans, reports what it would do and writes nothing' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)
        .and_return(measurement(lra: 9.0, input_i: -30.0, input_tp: -18.0))
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization)
      logged = []
      allow(Neutraliser.logger).to receive(:log) { |message| logged << message }

      result = processor.send(:process_file_compressed, '/m/film.mkv', film, measurement(lra: 16.0))

      expect(result).to include(status: :done, reason: :dry_run)
      expect(logged.join("\n")).to include('Compression: gentle', 'LRA 16.0 -> 9.0 LU', '[DRY RUN] Would compress (gentle)')
      expect(Neutraliser::FFmpegWrapper).not_to have_received(:apply_normalization)
    end

    it 'warns when even the strongest rung leaves the LRA over the target, and says a skipped boost was skipped' do
      boosting = Neutraliser::Processor.new(lra_target: 10, centre_boost: 4, dry_run: true)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement(lra: 14.0, input_i: -30.0, input_tp: -18.0))
      logged = []
      allow(Neutraliser.logger).to receive(:log) { |message| logged << message }

      stereo = ProbeFixture.source('/m/film.mkv', audio: [ProbeFixture.audio(channels: 2, layout: 'stereo')])
      boosting.send(:process_file_compressed, '/m/film.mkv', stereo, measurement(lra: 16.0))

      expect(logged.join("\n")).to include('even the strongest compression (extreme) leaves LRA above --lra-target 10.0',
                                           '--centre-boost skipped, the primary track is not 5.1 (layout: stereo)')
    end
  end

  describe 'FFmpegWrapper' do
    it 'measures the signal as a pre-filter leaves it' do
      allow(Neutraliser::FFmpegWrapper).to receive(:execute_with_timeout)
        .and_return(['', '{"input_i":"-30","input_tp":"-18","input_lra":"9","input_thresh":"-40","target_offset":"0"}', ok_status])

      Neutraliser::FFmpegWrapper.measure_loudness('a.mkv', audio_index: 1, pre_filter: 'acompressor=ratio=4')

      expect(Neutraliser::FFmpegWrapper).to have_received(:execute_with_timeout) do |cmd, *_|
        expect(cmd[cmd.index('-af') + 1]).to start_with('acompressor=ratio=4,loudnorm=')
      end
    end

    it 'filters and stamps a compression plan: chain then gain, mode compressed, the LRA before and after' do
      plan = Neutraliser::Compression::Plan.new(
        rung: Neutraliser::Compression::LADDER.first, centre_boost_db: 4.0, before: measurement(lra: 16.0),
        after: measurement(lra: 10.0, input_i: -28.0, input_tp: -15.0), lra_target: 10.0, reached: true,
        chain: 'pan=5.1|c0=c0,acompressor=ratio=2.5',
        gain_plan: Neutraliser::GainPlan.for(measurement(lra: 10.0, input_i: -28.0, input_tp: -15.0), profile)
      )
      allow(Neutraliser::FFmpegWrapper).to receive_messages(source_dialnorm: nil, execute_with_timeout: ['', '', ok_status])
      source = ProbeFixture.source('in.mkv', audio: [ProbeFixture.audio(codec: 'ac3', channels: 6, bit_rate: '448000')])

      result = Neutraliser::FFmpegWrapper.apply_normalization(
        source, 'out.mkv', measurement(lra: 16.0), profile, compression: plan
      )

      expect(result[:normalization_type]).to eq('Compressed')
      expect(Neutraliser::FFmpegWrapper).to have_received(:execute_with_timeout) do |cmd, *_|
        expect(cmd[cmd.index('-filter_complex') + 1]).to start_with('[0:a:0]pan=5.1|c0=c0,acompressor=ratio=2.5,volume=8.00dB')
        expect(cmd.each_cons(2).to_a).to include(
          ['-metadata:s:a:0', 'NEUTRALISER_MODE=compressed'], ['-metadata:s:a:0', 'NEUTRALISER_COMPRESSION=gentle'],
          ['-metadata:s:a:0', 'NEUTRALISER_CENTRE_BOOST_DB=4.00'], ['-metadata:s:a:0', 'NEUTRALISER_MEASURED_LRA=16.00'],
          ['-metadata:s:a:0', 'NEUTRALISER_LRA_AFTER=10.00'], ['-metadata:s:a:0', 'NEUTRALISER_GAIN_DB=8.00']
        )
      end
    end
  end

  # The ladder, run for real: ffmpeg compresses and levels a 5.1 clip, and the
  # output is read back with a different filter (ebur128) than the one that chose
  # the rung.
  describe 'on a real 5.1 clip', :real_ffmpeg do
    # ebur128 on the encoded output and loudnorm on the signal before the encode
    # read the LRA up to about 0.8 LU apart on a clip this short.
    let(:slack) { 1.0 }

    before(:all) do
      @skip_real = !system('which ffmpeg ffprobe > /dev/null 2>&1')
      next if @skip_real

      @dir = Dir.mktmpdir
      @source = LraFixture.build(File.join(@dir, 'film.mkv'), @dir)
      @source_levels = LraFixture.measure(@source)
    end
    after(:all) { FileUtils.remove_entry(@dir) if @dir }

    before { skip 'ffmpeg/ffprobe not available on PATH' if @skip_real }

    def copy_fixture(name)
      FileUtils.cp(@source, File.join(@dir, name)).then { File.join(@dir, name) }
    end

    def run_cli(*args)
      out, err = capture_stdout_and_stderr { Neutraliser::CLI.start(['process', '--replace', *args]) }
      "#{out}#{err}"
    rescue SystemExit => e
      raise "neutraliser exited #{e.status}" unless e.status.zero?

      ''
    end

    def capture_stdout_and_stderr
      out = StringIO.new
      err = StringIO.new
      real = [$stdout, $stderr]
      $stdout = out
      $stderr = err
      yield
      [out.string, err.string]
    ensure
      $stdout, $stderr = real
    end

    def stamp_of(path) = Neutraliser::Source.new(path).stamp

    it 'brings the LRA under the target (within tolerance), levels to the profile, stamps what it did and leaves other tracks alone' do
      expect(@source_levels[:lra]).to be_between(14.0, 19.0) # film-like: wide...
      expect(@source_levels[:i]).to be_between(-24.0, -20.0) # ...and quiet enough to need lifting
      path = copy_fixture('target12.mkv')
      run_cli('--lra-target', '12', path)

      after = LraFixture.measure(path)
      stamp = stamp_of(path)
      expect(after[:lra]).to be <= 12.0 + 1.0 + slack
      expect(after[:lra]).to be < @source_levels[:lra] - 3.0
      expect(after[:i]).to be_within(0.7).of(-20.0)
      expect(stamp).to be_compressed
      expect(stamp).to have_attributes(compression: 'gentle', measured_lra: be_within(1.0).of(@source_levels[:lra]))
      expect(stamp.lra_after).to be_within(slack).of(after[:lra])
      tracks = Neutraliser::Source.new(path).audio_tracks
      expect(tracks.map { |t| [t[:codec], t[:channels], t[:channel_layout], t[:language]] })
        .to eq(Neutraliser::Source.new(@source).audio_tracks.map { |t| [t[:codec], t[:channels], t[:channel_layout], t[:language]] })
      expect(tracks.first[:default]).to be true
      expect(LraFixture.measure(path, 1)[:i]).to be_within(1.0).of(LraFixture.measure(@source, 1)[:i])
    end

    it 'goes up the ladder for a tighter target, and a centre boost can stand in for a stronger rung' do
      plain = copy_fixture('plain.mkv')
      boosted = copy_fixture('boosted.mkv')
      run_cli('--lra-target', '7', plain)
      run_cli('--lra-target', '7', '--centre-boost', '4', boosted)

      names = Neutraliser::Compression::LADDER.map(&:name)
      expect(names.index(stamp_of(plain).compression)).to be > 0
      expect(LraFixture.measure(plain)[:lra]).to be <= 7.0 + 1.0 + slack
      expect(stamp_of(boosted)).to have_attributes(centre_boost_db: 4.0, compressed?: true)
      expect(names.index(stamp_of(boosted).compression)).to be < names.index(stamp_of(plain).compression)
    end

    it 'works with --limit-db: levels a hot target through the limiter and stamps it' do
      skip 'needs ffmpeg 5.1+ for the limiter' unless Neutraliser::FFmpegWrapper.wide_filter_options?
      path = copy_fixture('limited.mkv')
      run_cli('--lra-target', '12', '--target-level', '-10', '--limit-db', '10', path)

      stamp = stamp_of(path)
      expect(stamp).to be_compressed
      expect(stamp.compression).to end_with('+limiter')
      expect(LraFixture.measure(path)[:peak]).to be <= 0.0
    end

    it 'leaves a file already within the target as plain constant gain, then compresses it on a later, stricter run, once' do
      path = copy_fixture('sequence.mkv')
      run_cli('--lra-target', '30', path)
      expect(stamp_of(path)).to have_attributes(mode: 'linear', compression: nil, centre_boost_db: nil, lra_after: nil)
      expect(LraFixture.measure(path)[:lra]).to be_within(slack).of(@source_levels[:lra])

      before = File.binread(path)
      expect(run_cli('--dry-run', '--lra-target', '12', path)).to include('[DRY RUN] Would compress (gentle)')
      expect(File.binread(path)).to eq(before)

      run_cli('--lra-target', '12', path)
      expect(stamp_of(path)).to be_compressed
      expect(run_cli('--lra-target', '12', path)).to include('Already processed, skipping')
    end
  end
end
