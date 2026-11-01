# frozen_string_literal: true

require 'spec_helper'
require_relative 'support/dolby_fixture'

# Constant gain has to be constant gain on Dolby tracks too (research:
# docs/research/0002-streaming-loudness-and-dialogue/research.md, "Two bugs this research found").
# Real `process --replace` runs over generated AC-3 / E-AC-3 clips, judged with ebur128 and a raw-stream read
# of the output, neither of which is neutraliser's own measure.
RSpec.describe 'Dolby loudness metadata through process --replace', :real_ffmpeg do
  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
  end

  let(:tmp) { Dir.mktmpdir }
  let(:no_drc) { ['-drc_scale', 0] }
  # A decoder that honours dialnorm, in line mode: gain of (-31 - dialnorm).
  let(:honours_dialnorm) { ['-target_level', -31] }

  after { FileUtils.remove_entry(tmp) }

  def process(path, target:, tolerance:)
    Neutraliser::Processor.new(replace: true, target_level: target, tolerance: tolerance, cache: false).process(path)
  end

  describe 'stream DRC' do
    # The stream's dynrng words squash the loud passages by ~8 dB. FFmpeg's default decode applies them, so before
    # the fix measurement and re-encode both heard the compressed signal and made it permanent.
    it 'is not baked in: the output keeps the source loudness range, and the stamp measures it without DRC' do
      wav = DolbyFixture.programme(File.join(tmp, 'programme.wav'))
      plain = DolbyFixture.encode(wav, File.join(tmp, 'plain.ac3'), codec: 'ac3', dialnorm: -31)
      with_drc = Ac3Bits.add_dynrng(plain) do |i|
        (i * DolbyFixture::FRAME_SECONDS) % DolbyFixture::LOUD_EVERY < DolbyFixture::LOUD_LEN ? DolbyFixture::LOUD_DYNRNG : 0
      end
      File.binwrite(File.join(tmp, 'with_drc.ac3'), with_drc)
      mkv = DolbyFixture.mkv(File.join(tmp, 'with_drc.ac3'), File.join(tmp, 'film.mkv'))

      frames = Ac3Bits.frames(with_drc).map { |offset, size| with_drc.byteslice(offset, size) }
      expect(frames).to all(satisfy { |frame| Ac3Bits.has_dynrng?(frame) })
      before_off = DolbyFixture.measure(mkv, *no_drc)
      before_default = DolbyFixture.measure(mkv)
      expect(before_off[:lra] - before_default[:lra]).to be > 4, 'fixture: the DRC words should compress the default decode'

      process(mkv, target: (before_off[:i] + 3).round(1), tolerance: 0.5)

      after_off = DolbyFixture.measure(mkv, *no_drc)
      expect(after_off[:lra]).to be_within(1.0).of(before_off[:lra])
      stamp = Neutraliser::FFmpegWrapper.read_stamp(mkv)
      expect(stamp).to have_attributes(mode: 'linear', recipe: Neutraliser::Recipe::CURRENT)
      expect(stamp.measured_lra).to be_within(1.0).of(before_off[:lra])
      expect(stamp.measured_i).to be_within(0.5).of(before_off[:i])
      expect(after_off[:i] - before_off[:i]).to be_within(0.5).of(3.0)
    end
  end

  describe 'dialnorm' do
    # Both files carry dialnorm -24 and are 6 LU apart; the louder is near target and left alone, the quieter gets +6 dB.
    # Before the fix the encoder wrote -31, so a dialnorm-honouring decode (-7 dB) put the pair 7 LU apart the other way.
    %w[ac3 eac3].each do |codec|
      it "is carried across the re-encode, so the pair stays level on a decoder that honours it (#{codec})" do
        wav = DolbyFixture.programme(File.join(tmp, 'programme.wav'))
        quiet_wav = DolbyFixture.programme(File.join(tmp, 'quiet.wav'), gain_db: -6)
        library = File.join(tmp, 'library')
        FileUtils.mkdir_p(library)
        clips = { 'near.mkv' => wav, 'quiet.mkv' => quiet_wav }.to_h do |name, source|
          stream = File.join(tmp, "#{name}.#{codec}")
          DolbyFixture.encode(source, stream, codec: codec, dialnorm: -24)
          [name, DolbyFixture.mkv(stream, File.join(library, name))]
        end
        near, quiet = clips.values_at('near.mkv', 'quiet.mkv')
        target = DolbyFixture.measure(near, *no_drc)[:i].round(1)
        gap_before = DolbyFixture.measure(near, *honours_dialnorm)[:i] - DolbyFixture.measure(quiet, *honours_dialnorm)[:i]
        expect(gap_before).to be_within(0.5).of(6.0)

        process(library, target: target, tolerance: 1.0)

        expect(DolbyFixture.measure(near, *no_drc)[:i] - DolbyFixture.measure(quiet, *no_drc)[:i]).to be_within(0.5).of(0.0)
        gap_after = DolbyFixture.measure(near, *honours_dialnorm)[:i] - DolbyFixture.measure(quiet, *honours_dialnorm)[:i]
        expect(gap_after).to be_within(0.5).of(0.0)
        expect(Neutraliser::DolbyStream.dialnorm(DolbyFixture.raw_stream(quiet, codec))).to eq(-24)
        expect(Neutraliser::FFmpegWrapper.read_stamp(quiet)).to have_attributes(mode: 'linear', source_codec: codec, source_dialnorm: -24)
        expect(Neutraliser::FFmpegWrapper.read_stamp(near)).to be_nil
      end
    end
  end
end
