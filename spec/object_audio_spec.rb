require 'spec_helper'

RSpec.describe Neutraliser::ObjectAudio do
  let(:ok_status) { instance_double(Process::Status, success?: true) }

  # Feeds a canned ffprobe stream entry through the real track parser, so the
  # detector sees exactly the shape detect_audio_tracks hands the Processor.
  def probed_track(codec:, profile: nil, title: nil, channels: 6)
    stream = { index: 1, codec_name: codec, channels: channels, sample_rate: '48000' }
    stream[:profile] = profile if profile
    stream[:tags] = { title: title } if title
    allow(Neutraliser::FFmpegWrapper).to receive(:execute_with_timeout)
      .and_return([{ streams: [stream] }.to_json, '', ok_status])
    Neutraliser::FFmpegWrapper.detect_audio_tracks('movie.mkv').first
  end

  describe '.detect from the stream profile' do
    {
      'E-AC3 JOC (DDP Atmos)' => ['eac3', 'Dolby Digital Plus + Dolby Atmos'],
      'TrueHD Atmos' => ['truehd', 'Dolby TrueHD + Dolby Atmos'],
      'DTS:X' => ['dts', 'DTS-HD MA + DTS:X'],
      'DTS:X IMAX' => ['dts', 'DTS-HD MA + DTS:X IMAX']
    }.each do |format, (codec, profile)|
      it "flags #{format} without a second probe" do
        track = probed_track(codec: codec, profile: profile)
        expect(Neutraliser::FFmpegWrapper).not_to receive(:probe_audio_profile_mid_file)

        verdict = described_class.detect('movie.mkv', track, name: 'movie.mkv')

        expect(verdict).to have_attributes(status: :object_audio, profile: profile)
      end
    end

    {
      'plain E-AC3' => ['eac3', nil],
      'plain TrueHD' => ['truehd', nil],
      'DTS-HD MA without X' => ['dts', 'DTS-HD MA'],
      'AAC' => %w[aac LC]
    }.each do |format, (codec, profile)|
      it "passes #{format}" do
        track = probed_track(codec: codec, profile: profile)
        expect(Neutraliser::FFmpegWrapper).not_to receive(:probe_audio_profile_mid_file)

        expect(described_class.detect('movie.mkv', track, name: 'movie.mkv').status).to eq(:none)
      end
    end
  end

  describe '.detect when the name hints at object audio' do
    let(:name) { 'Severance.S02E01.2160p.ATVP.WEB-DL.DDP5.1.Atmos.H.265.mkv' }

    it 'confirms with a mid-file probe when the stream profile came back unknown' do
      track = probed_track(codec: 'eac3')
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_audio_profile_mid_file)
        .with('work.mkv', track).and_return('Dolby Digital Plus + Dolby Atmos')

      verdict = described_class.detect('work.mkv', track, name: name)

      expect(verdict).to have_attributes(status: :object_audio, profile: 'Dolby Digital Plus + Dolby Atmos')
    end

    it 'never skips on the name alone: unconfirmed is only :suspected' do
      track = probed_track(codec: 'eac3')
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_audio_profile_mid_file).and_return(nil)

      verdict = described_class.detect('work.mkv', track, name: name)

      expect(verdict.status).to eq(:suspected)
      expect(verdict.object_audio?).to be(false)
    end

    it 'reads the track title as a hint too' do
      track = probed_track(codec: 'truehd', title: 'TrueHD Atmos 7.1')
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_audio_profile_mid_file).and_return(nil)

      expect(described_class.detect('work.mkv', track, name: 'movie.mkv').status).to eq(:suspected)
    end

    it 'skips the second probe for codecs that cannot carry object audio' do
      track = probed_track(codec: 'aac', channels: 2)
      expect(Neutraliser::FFmpegWrapper).not_to receive(:probe_audio_profile_mid_file)

      expect(described_class.detect('work.mkv', track, name: name).status).to eq(:none)
    end
  end

  describe '.hinted?' do
    it 'matches common release-name spellings' do
      %w[Film.DDP5.1.Atmos.mkv Film.TrueHD.7.1.ATMOS.mkv Film.DTS-X.mkv Film.DTS.X.7.1.mkv
         Film.DTSX.mkv Film.EAC3.JOC.mkv].each do |name|
        expect(described_class.hinted?(name)).to be(true), name
      end
    end

    it 'ignores look-alikes' do
      %w[Film.DTS.x264.mkv Film.DTS-HD.MA.mkv Film.Atom.mkv].each do |name|
        expect(described_class.hinted?(name)).to be(false), name
      end
    end
  end
end
