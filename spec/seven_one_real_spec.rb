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

  it 'levels a 7.1 clip to within 0.5 LU of the target through process --replace' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'pcm71.mkv')
      FileUtils.cp(@pcm71, path)
      out = StringIO.new
      real = [$stdout, $stderr]
      $stdout = $stderr = out
      begin
        Neutraliser::CLI.start(['process', '--replace', path])
      rescue SystemExit => e
        raise "neutraliser exited #{e.status}:\n#{out.string}" unless e.status.zero?
      ensure
        $stdout, $stderr = real
      end

      expect(ebur128(path)).to be_within(0.5).of(Neutraliser::Profiles.find('livingroom')[:lufs])
    end
  end
end
