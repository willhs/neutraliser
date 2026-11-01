# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'json'
require 'open3'
require_relative 'support/dolby_fixture'
require_relative 'support/eac3_bits'

# Regressions for what docs/research/0003-sceptical-review-dolby-dialogue-compression/research.md found, on real
# `process` runs over generated clips: which rung a run really picks, what --resume really looks at again, what a
# stamp says after a second pass, and what a flatten leaves on record.
RSpec.describe 'Sceptical review regressions', :real_ffmpeg do
  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
  end

  let(:tmp) { Dir.mktmpdir }
  let(:current) { Neutraliser::Recipe::CURRENT }

  after { FileUtils.remove_entry(tmp) }

  def process(path, **options)
    Neutraliser::Processor.new(replace: true, cache: false, **options).process(path)
  end

  def stamp(path) = Neutraliser::Source.new(path).stamp
  def sha(path) = Digest::SHA256.file(path).hexdigest
  def lra(path) = DolbyFixture.measure(path, '-drc_scale', 0)[:lra]

  # A stereo AC-3 clip of pink noise steps: [[seconds, dBFS amplitude], ...].
  def steps_clip(name, steps)
    wav = File.join(tmp, "#{name}.wav")
    inputs = steps.each_with_index.flat_map do |(seconds, db), i|
      ['-f', 'lavfi', '-i', format('anoisesrc=color=pink:seed=%d:duration=%d:sample_rate=48000:amplitude=%.5f', i + 1, seconds, 10**(db / 20.0))]
    end
    labels = steps.each_index.map { |i| "[#{i}:a]" }.join
    DolbyFixture.ffmpeg(*inputs, '-filter_complex', "#{labels}concat=n=#{steps.size}:v=0:a=1,aformat=channel_layouts=stereo[mix]",
                        '-map', '[mix]', '-c:a', 'pcm_s24le', wav)
    stream = File.join(tmp, "#{name}.ac3")
    DolbyFixture.encode(wav, stream, codec: 'ac3', dialnorm: -27)
    DolbyFixture.mkv(stream, File.join(tmp, "#{name}.mkv"))
  end

  def wide_clip(dir: tmp, name: 'film.mkv')
    wav = DolbyFixture.programme(File.join(tmp, 'programme.wav'), seconds: 24)
    stream = File.join(tmp, 'programme.ac3')
    DolbyFixture.encode(wav, stream, codec: 'ac3', dialnorm: -27)
    DolbyFixture.mkv(stream, File.join(dir, name))
  end

  # The file as an older recipe's run would have left it: the same tags, with that recipe.
  def retag_recipe(path, recipe)
    retagged = "#{path}.retagged.mkv"
    DolbyFixture.ffmpeg('-i', path, '-map', '0', '-c', 'copy', '-metadata:s:a:0', "NEUTRALISER_RECIPE=#{recipe}",
                        '-metadata', "NEUTRALISER_RECIPE=#{recipe}", retagged)
    File.rename(retagged, path)
  end

  # The rung-by-rung case is in compression_spec.rb on measured figures: real clips that show it sit on the LRA gate's
  # edge, where a different noise seed moves a rung's LRA by 14 LU (research note, lab/05b_ladder_cases.rb).
  describe 'the compression ladder, whose LRA does not fall steadily' do
    # The source's range is narrow only because the bed is under the gate. Every rung leaves it as it is, or wider
    # (the strongest by 8 LU), and the old code applied the strongest because it couldn't reach the target.
    it 'levels without compressing when no rung would narrow the range' do
      film = steps_clip('bursts', [[4, -48], [4, -12]] * 4)
      before = lra(film)

      process(film, lra_target: 3.0, tolerance: 1.0)

      expect(stamp(film).mode).to eq('linear')
      expect(lra(film)).to be_within(1.0).of(before)
    end
  end

  describe '--resume against a manifest from before' do
    let(:library) { File.join(tmp, 'library').tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:film) { wide_clip(dir: library) }

    # A run recorded "normalized" for the file, then it was left as recipe 1 would have left it.
    before do
      film
      process(library)
      retag_recipe(film, 1)
      FileUtils.rm_f(File.join(library, Neutraliser::SkipDecider::FILENAME))
    end

    it 'still trusts the manifest for a run asking the same thing' do
      expect(process(library, resume: true)).to include(resumed: 1, queued: 0)
    end

    it 'looks again at a normalised file when the run redoes its recipe' do
      expect(process(library, resume: true, redo_recipes: [1])).to include(resumed: 0, queued: 1)
    end

    it 'looks again at a normalised file when the run asks for compression' do
      summary = process(library, resume: true, lra_target: 8.0)

      expect(summary).to include(resumed: 0, compressed: 1)
      expect(stamp(film).mode).to eq('compressed')
    end
  end

  describe 'a stamp after a second pass' do
    let(:film) { wide_clip }

    it 'has no prior on a first pass' do
      process(film)

      expect(stamp(film)).to have_attributes(mode: 'linear', prior: nil)
    end

    it 'keeps what an earlier pass did, so `linear` on compressed audio does not read as all that happened' do
      process(film, lra_target: 8.0, tolerance: 1.0)
      first = stamp(film)
      level = DolbyFixture.measure(film)[:i]

      process(film, target_level: (level - 6).round(1), tolerance: 1.0)

      expect(first.mode).to eq('compressed')
      expect(stamp(film)).to have_attributes(mode: 'linear', prior: "#{current}:compressed/#{first.compression}")
    end

    it 'names the older recipe a re-encode went over, whose DRC and dialnorm damage it cannot undo' do
      process(film, target_level: -24.0, tolerance: 1.0)
      retag_recipe(film, 1)

      process(film, target_level: -21.0, tolerance: 1.0)

      expect(stamp(film)).to have_attributes(mode: 'linear', recipe: current, prior: '1:linear')
    end

    it 'chains every earlier pass, oldest first' do
      process(film, target_level: -24.0, tolerance: 1.0)
      process(film, target_level: -21.0, tolerance: 1.0)
      process(film, target_level: -18.0, tolerance: 1.0)

      expect(stamp(film).prior).to eq("#{current}:linear,#{current}:linear")
    end

    it 'never compresses twice, even after a linear pass went on top' do
      process(film, lra_target: 8.0, tolerance: 1.0)
      process(film, target_level: -24.0, tolerance: 1.0)
      levelled = sha(film)

      process(film, target_level: -24.0, tolerance: 1.0, lra_target: 3.0)

      expect(sha(film)).to eq(levelled)
    end

    it 'shows up in report, so the count of `linear` files can be read for what it is' do
      process(film, lra_target: 8.0, tolerance: 1.0)
      process(film, target_level: -24.0, tolerance: 1.0)

      report = Neutraliser::Report.new(film)

      expect(report.counts[:reencoded]).to eq(1)
      expect(report.summary).to include('Re-encoded over an earlier pass: 1')
      expect(report.to_tsv.lines.last.split("\t")).to include(a_string_matching(/\A\d+:compressed/))
    end
  end

  # Carrying on would have the encoder write -31 over the source's dialnorm, for good, on a library with no originals.
  describe 'a dialnorm read that fails' do
    let(:film) { wide_clip }

    it 'fails the file and leaves it alone when ffmpeg could not run the read' do
      film
      before = sha(film)
      allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_raise(Neutraliser::FFmpegError, 'No space left on device')

      expect(process(film)).to include(failed: 1, done: 0)
      expect(sha(film)).to eq(before)
    end

    it 'fails the file and leaves it alone on a disk error' do
      film
      before = sha(film)
      allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_raise(Errno::ENOSPC)

      expect(process(film)).to include(failed: 1, done: 0)
      expect(sha(film)).to eq(before)
    end

    it 'still processes a track whose bytes hold no dialnorm: that is the track, and no retry changes it' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_dialnorm).and_raise(Neutraliser::NoDialnormError, 'no dialnorm in the first frames')

      expect(process(film)).to include(failed: 0, done: 1)
      expect(stamp(film)).to have_attributes(mode: 'linear', source_dialnorm: nil)
    end
  end

  describe 'what the planned flags leave on record' do
    def dts_clip
      wav = DolbyFixture.programme(File.join(tmp, 'programme.wav'), seconds: 8)
      path = File.join(tmp, 'dts.mkv')
      DolbyFixture.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=8', '-i', wav, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264',
                          '-preset', 'ultrafast', '-strict', '-2', '-c:a', 'dca', '-b:a', '768k', '-ar', '48000', '-shortest', path)
      path
    end

    # An E-AC-3 stream a real decoder (7.1+) reports as Atmos, with DRC words on its loud passages.
    def atmos_clip
      wav = DolbyFixture.programme(File.join(tmp, 'programme.wav'), seconds: 24)
      stream = File.join(tmp, 'plain.eac3')
      DolbyFixture.encode(wav, stream, codec: 'eac3', dialnorm: -27, options: ['-channel_coupling', '0'])
      with_drc = Eac3Bits.add_dynrng(File.binread(stream)) do |i|
        (i * DolbyFixture::FRAME_SECONDS) % DolbyFixture::LOUD_EVERY < DolbyFixture::LOUD_LEN ? DolbyFixture::LOUD_DYNRNG : 0
      end
      File.binwrite(stream, Eac3Bits.add_atmos_flag(with_drc))
      DolbyFixture.mkv(stream, File.join(tmp, 'atmos.mkv'))
    end

    it 'names the source profile a codec change converted from' do
      film = dts_clip

      process(film, allow_codec_change: true)

      expect(Neutraliser::Source.new(film).audio_tracks.first[:codec]).to eq('flac')
      expect(stamp(film)).to have_attributes(mode: 'linear', source_codec: 'dts', source_profile: 'DTS', source_dialnorm: nil)
    end

    it 'names the object audio a flatten dropped, keeps its dialnorm and leaves its DRC out' do
      skip 'Atmos needs ffmpeg 7.1+ to name' unless ((Neutraliser::FFmpegWrapper.version || [99, 0]) <=> [7, 1]) >= 0

      film = atmos_clip
      expect(Neutraliser::Source.new(film).audio_tracks.first[:profile]).to match(/Atmos/)
      before = lra(film)

      process(film, allow_object_audio_loss: true)

      expect(stamp(film)).to have_attributes(mode: 'linear', source_codec: 'eac3', source_dialnorm: -27, source_profile: a_string_matching(/Atmos/))
      expect(Neutraliser::DolbyStream.dialnorm(DolbyFixture.raw_stream(film, 'eac3'))).to eq(-27)
      expect(lra(film)).to be_within(1.0).of(before)
    end
  end
end
