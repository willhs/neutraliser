require 'spec_helper'

RSpec.describe Neutraliser::FFmpegWrapper do
  let(:ok_status) { instance_double(Process::Status, success?: true) }
  let(:fail_status) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  describe '.measure_loudness' do
    it 'executes ffmpeg with loudnorm json output and parses results' do
      stderr = <<~OUT
        [Parsed_loudnorm_0 @ 0x123]
        {
          "input_i" : "-18.5",
          "input_tp" : "-2.1",
          "input_lra" : "8.3",
          "input_thresh" : "-28.9",
          "target_offset" : "1.5"
        }
      OUT
      allow(Open3).to receive(:capture3).and_return(['', stderr, ok_status])

      result = described_class.measure_loudness('test.mp4', target_i: -20.0, target_tp: -1.5, target_lra: 12.0)

      expect(Open3).to have_received(:capture3).with(
        'ffmpeg', '-hide_banner', '-nostats', '-i', 'test.mp4',
        '-map', 'a:0',
        '-af', 'loudnorm=I=-20.0:TP=-1.5:LRA=12.0:print_format=json',
        '-f', 'null', '-'
      )
      expect(result['input_i']).to eq('-18.5')
    end

    it 'raises FFmpegError including stderr when command fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'boom', fail_status])

      expect { described_class.measure_loudness('missing.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

  describe '.quick_loudness_sample' do
    it 'returns nil when file is too short for meaningful sample' do
      allow(Open3).to receive(:capture3).and_return(['40', '', ok_status])

      result = described_class.quick_loudness_sample('short.mp4', duration: 30)
      expect(result).to be_nil
    end
  end

  describe '.apply_normalization_with_multiple_tracks' do
    let(:measured_data) do
      {
        'input_i' => '-18.5',
        'input_tp' => '-2.1',
        'input_lra' => '8.3',
        'input_thresh' => '-28.9',
        'target_offset' => '1.5'
      }
    end

    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0 } }

    it 'uses source-matched codec for primary track and copies additional tracks' do
      tracks = [
        { index: 0, channels: 6, codec: 'ac3', bit_rate: 448_000, sample_rate: 48_000 },
        { index: 1, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
      ]
      allow(Open3).to receive(:capture3).and_return(['', '', ok_status])

      result = described_class.apply_normalization_with_multiple_tracks('in.mkv', 'out.mkv', measured_data, tracks, profile)

      expect(Open3).to have_received(:capture3) do |*args|
        expect(args).to include('-c:a:0', 'ac3', '-b:a:0', '448k')
        expect(args).to include('-map', '0:a:1', '-c:a:1', 'copy')
      end
      expect(result[:encoder]).to eq('ac3')
      expect(result[:bitrate]).to eq(448_000)
    end
  end

  describe '.detect_audio_tracks' do
    it 'parses ffprobe csv output including bitrate and sample rate' do
      ffprobe_csv = "1,6,ac3,640000,48000\n2,2,aac,256000,44100\n"
      allow(Open3).to receive(:capture3).and_return([ffprobe_csv, '', ok_status])

      result = described_class.detect_audio_tracks('test.mp4')

      expect(result).to eq([
        { index: 0, stream_index: 1, channels: 6, codec: 'ac3', bit_rate: 640000, sample_rate: 48000 },
        { index: 1, stream_index: 2, channels: 2, codec: 'aac', bit_rate: 256000, sample_rate: 44100 }
      ])
    end

    it 'returns a default track when ffprobe fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'err', fail_status])

      result = described_class.detect_audio_tracks('bad.mp4')
      expect(result).to eq([{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }])
    end

    it 'handles missing bitrate fields gracefully' do
      ffprobe_csv = "1,6,flac,N/A,48000\n"
      allow(Open3).to receive(:capture3).and_return([ffprobe_csv, '', ok_status])

      result = described_class.detect_audio_tracks('test.mkv')

      expect(result.first[:bit_rate]).to eq(0)
      expect(result.first[:sample_rate]).to eq(48000)
    end
  end

  describe '.select_output_codec' do
    def make_track(codec:, channels: 2, bit_rate: 256_000, sample_rate: 48_000)
      { index: 0, stream_index: 0, channels: channels, codec: codec, bit_rate: bit_rate, sample_rate: sample_rate }
    end

    it 'matches source AAC codec and bitrate for MP4' do
      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 512_000), 'out.mp4')
      expect(result[:encoder]).to eq('aac')
      expect(result[:bitrate]).to eq(320_000) # capped at AAC stereo max
    end

    it 'matches source AC3 for MKV' do
      result = described_class.send(:select_output_codec, make_track(codec: 'ac3', channels: 6, bit_rate: 448_000), 'out.mkv')
      expect(result[:encoder]).to eq('ac3')
      expect(result[:bitrate]).to eq(448_000)
    end

    it 'enforces quality floor when source bitrate is low' do
      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 64_000), 'out.mp4')
      expect(result[:encoder]).to eq('aac')
      expect(result[:bitrate]).to eq(128_000)
    end

    it 'caps bitrate at codec maximum' do
      result = described_class.send(:select_output_codec, make_track(codec: 'ac3', channels: 6, bit_rate: 900_000), 'out.mp4')
      expect(result[:bitrate]).to eq(640_000)
    end

    it 'falls back to FLAC for DTS source in MKV' do
      result = described_class.send(:select_output_codec, make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), 'out.mkv')
      expect(result[:encoder]).to eq('flac')
      expect(result[:lossless_output]).to eq(true)
      expect(result[:bitrate]).to be_nil
    end

    it 'falls back to EAC3 for DTS source in MP4' do
      result = described_class.send(:select_output_codec, make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), 'out.mp4')
      expect(result[:encoder]).to eq('eac3')
    end

    it 'falls back to FLAC for TrueHD source in MKV' do
      result = described_class.send(:select_output_codec, make_track(codec: 'truehd', channels: 6, bit_rate: 0), 'out.mkv')
      expect(result[:encoder]).to eq('flac')
      expect(result[:lossless_output]).to eq(true)
    end

    it 'preserves FLAC for lossless source in MKV' do
      result = described_class.send(:select_output_codec, make_track(codec: 'flac', channels: 2, bit_rate: 0), 'out.mkv')
      expect(result[:encoder]).to eq('flac')
      expect(result[:lossless_output]).to eq(true)
    end

    it 'falls back to high-bitrate AAC for FLAC source in MP4' do
      result = described_class.send(:select_output_codec, make_track(codec: 'flac', channels: 2, bit_rate: 0), 'out.mp4')
      expect(result[:encoder]).to eq('aac')
      expect(result[:bitrate]).to eq(128_000)
    end

    it 'uses libopus for Opus source in WebM' do
      result = described_class.send(:select_output_codec, make_track(codec: 'opus', bit_rate: 128_000), 'out.webm')
      expect(result[:encoder]).to eq('libopus')
      expect(result[:bitrate]).to eq(128_000)
    end

    it 'uses libmp3lame for MP3 source in MP4' do
      result = described_class.send(:select_output_codec, make_track(codec: 'mp3', bit_rate: 320_000), 'out.mp4')
      expect(result[:encoder]).to eq('libmp3lame')
      expect(result[:bitrate]).to eq(320_000)
    end

    it 'handles unknown source codec with container fallback' do
      result = described_class.send(:select_output_codec, make_track(codec: 'unknown', bit_rate: 0), 'out.mp4')
      expect(result[:encoder]).to eq('aac')
    end

    it 'uses quality floor when source bitrate is unknown' do
      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 0), 'out.mp4')
      expect(result[:bitrate]).to eq(128_000)
    end
  end

  describe '.parse_loudnorm_json' do
    it 'raises a clear error when no loudnorm json is present' do
      expect { described_class.send(:parse_loudnorm_json, 'no json here') }
        .to raise_error(Neutraliser::FFmpegError, /loudnorm JSON not found/)
    end
  end
end
