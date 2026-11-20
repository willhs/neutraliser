require 'spec_helper'
require 'fileutils'
require 'stringio'
require_relative 'support/lra_fixture'
require_relative 'support/ladder_fixture'

# Research 0003 finding 14: loudnorm ignores channels 7 and 8, so a 7.1 file's level was read low (the
# same noise on all eight read -27.0 by loudnorm and -25.3 by ebur128) and the file landed about 1.7 LU
# over target. Run for real on a generated PCM 7.1 clip, and read back with ebur128.
RSpec.describe 'Loudness of 7.1 files (finding 14)', :real_ffmpeg do
  before(:all) do
    @skip_real = !system('which ffmpeg ffprobe > /dev/null 2>&1')
    next if @skip_real

    @fixtures = Dir.mktmpdir
    @pcm71 = File.join(@fixtures, 'pcm71.mkv')
    @pcm51 = File.join(@fixtures, 'pcm51.mkv')
    # The same pink noise on every channel, so the side channels carry as much energy as the rest.
    { @pcm71 => '7.1', @pcm51 => '5.1' }.each do |path, layout|
      LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                      '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=8:rate=10',
                      '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=8:sample_rate=48000:amplitude=0.1:seed=1',
                      '-filter_complex', "[1:a]aformat=channel_layouts=mono,pan=#{layout}|#{(0...(layout == '7.1' ? 8 : 6)).map { |c| "c#{c}=c0" }.join('|')}[a]",
                      '-map', '0:v', '-map', '[a]', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'pcm_s24le', path)
    end
  end
  after(:all) { FileUtils.remove_entry(@fixtures) if @fixtures }

  before { skip 'ffmpeg/ffprobe not available on PATH' if @skip_real }

  def ebur128(path) = LraFixture.measure(path)[:i]

  it 'reads a 7.1 clip as ebur128 does, side channels included' do
    track = { index: 0, channels: 8 }
    measured = Neutraliser::FFmpegWrapper.measure_loudness(@pcm71, audio_index: 0, channels: track[:channels])

    expect(measured.input_i).to be_within(0.2).of(ebur128(@pcm71))
  end

  it 'reads the loudness range over every channel, as ebur128 does (loudnorm reads 0.1 for range in the sides)' do
    Dir.mktmpdir do |dir|
      path = LadderFixture.build(:sides71, File.join(dir, 'sides71.mkv'))
      measured = Neutraliser::FFmpegWrapper.measure_loudness(path, audio_index: 0, channels: 8)

      expect(measured.input_lra).to be_within(0.5).of(LraFixture.measure(path)[:lra])
      expect(measured.input_lra).to be > 13.0
    end
  end

  it 'leaves a 5.1 clip on the plain loudnorm read (no change below 7 channels)' do
    plain = Neutraliser::FFmpegWrapper.measure_loudness(@pcm51, audio_index: 0)
    counted = Neutraliser::FFmpegWrapper.measure_loudness(@pcm51, audio_index: 0, channels: 6)

    expect(counted).to eq(plain)
  end

  def run_cli(*args)
    out = StringIO.new
    real = [$stdout, $stderr]
    $stdout = $stderr = out
    begin
      Neutraliser::CLI.start(args)
    rescue SystemExit => e
      raise "neutraliser exited #{e.status}:\n#{out.string}" unless e.status.zero?
    ensure
      $stdout, $stderr = real
    end
    out.string
  end

  let(:livingroom) { Neutraliser::Profiles.find('livingroom') }

  it 'levels a 7.1 clip to within 0.5 LU of the target through process --replace' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pcm71.mkv')
      FileUtils.cp(@pcm71, path)
      run_cli('process', '--replace', path)

      expect(ebur128(path)).to be_within(0.5).of(livingroom[:lufs])
    end
  end

  # Sceptical review of 7.1 (docs/research/0007-*): loudnorm's `offset=` is extra gain when it runs in
  # dynamic mode (--allow-dynamic, the night profile, a file that does not fit linear). The 7.1 read replaced
  # the offset with the linear-mode gain (target - integrated), so a dynamic pass added it a second time
  # and a 7.1 clip came out about 14 dB over target (-5.7 LUFS for -20).
  { '--allow-dynamic' => [-20.0, ['--allow-dynamic']],
    'the night profile' => [-16.0, ['--profile', 'night']] }.each do |label, (target, flags)|
    it "levels a 7.1 clip to within 1 LU of the target under #{label} (loudnorm dynamic)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'pcm71.mkv')
        FileUtils.cp(@pcm71, path)
        run_cli('process', '--replace', *flags, path)

        expect(ebur128(path)).to be_within(1.0).of(target)
      end
    end
  end

  # Review findings 3 and 7 (docs/research/pre-release-review-2026-11.md): a `.loudnorm_livingroom.json`
  # written before the side channels were metered holds the six-channel figure, which reads a 7.1 file
  # low, so the file would be levelled up too far. The cache version was not bumped with the meter.
  it 'does not trust a 7.1 analysis cached under the six-channel meter (cache version 1.2)' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pcm71.mkv')
      FileUtils.cp(@pcm71, path)
      six_channel = Neutraliser::FFmpegWrapper.measure_loudness(path, audio_index: 0)
      cache = Neutraliser::CacheManager.new
      cache.save_analysis(path, livingroom, six_channel)
      cache_file = cache.cache_path(path, livingroom)
      File.write(cache_file, File.read(cache_file).sub(/"cache_version": "[^"]+"/, '"cache_version": "1.2"'))
      expect(ebur128(path) - six_channel.input_i).to be > 1.0 # the figure the old build cached is wrong

      run_cli('process', '--replace', path)

      expect(ebur128(path)).to be_within(0.5).of(livingroom[:lufs])
    end
  end

  # Finding 7: files already levelled by the six-channel meter carry a recipe 2 stamp, which
  # --redo-recipe refuses (it is the recipe a run writes). --redo-side-channels finds them by channel
  # count and stamp date, and a second run does not find them again.
  describe '--redo-side-channels' do
    def stamped_seven_one(dir, date:, over_target: 1.7)
      path = File.join(dir, 'stamped71.mkv')
      LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', @pcm71, '-map', '0', '-c', 'copy',
                      '-af', "volume=#{livingroom[:lufs] + over_target - ebur128(@pcm71)}dB", '-c:a', 'pcm_s24le',
                      '-metadata', 'NEUTRALISER_PROFILE=livingroom', '-metadata', 'NEUTRALISER_RECIPE=2',
                      '-metadata', 'NEUTRALISER_MODE=linear', '-metadata', "NEUTRALISER_DATE=#{date}", path)
      path
    end

    it 'leaves a stamped 7.1 file alone by default and re-levels it with the flag, once' do
      Dir.mktmpdir do |dir|
        path = stamped_seven_one(dir, date: '2026-11-10T00:00:00Z')
        louder = ebur128(path)
        expect(louder).to be > livingroom[:lufs] + 1.0

        run_cli('process', '--replace', path)
        expect(ebur128(path)).to be_within(0.05).of(louder)

        run_cli('process', '--replace', '--redo-side-channels', path)
        expect(ebur128(path)).to be_within(0.5).of(livingroom[:lufs])

        redone = ebur128(path)
        run_cli('process', '--replace', '--redo-side-channels', path)
        expect(ebur128(path)).to be_within(0.05).of(redone)
      end
    end

    it 'leaves a 7.1 file stamped after the side channels were metered alone' do
      Dir.mktmpdir do |dir|
        path = stamped_seven_one(dir, date: '2026-11-20T00:00:00Z')
        louder = ebur128(path)

        run_cli('process', '--replace', '--redo-side-channels', path)

        expect(ebur128(path)).to be_within(0.05).of(louder)
      end
    end
  end
end
