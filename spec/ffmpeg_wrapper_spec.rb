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

    it 'uses stream-specific codec for primary track and copies additional tracks' do
      tracks = [
        { index: 0, channels: 6, codec: 'ac3' },
        { index: 1, channels: 2, codec: 'aac' }
      ]
      allow(Open3).to receive(:capture3).and_return(['', '', ok_status])

      described_class.apply_normalization_with_multiple_tracks('in.mp4', 'out.mp4', measured_data, tracks, profile)

      expect(Open3).to have_received(:capture3) do |*args|
        expect(args).to include('-c:a:0', 'ac3', '-b:a:0', '640k')
        expect(args).to include('-map', '0:a:1', '-c:a:1', 'copy')
      end
    end
  end

  describe '.detect_audio_tracks' do
    it 'parses ffprobe csv output' do
      ffprobe_csv = "1,6,ac3\n2,2,aac\n"
      allow(Open3).to receive(:capture3).and_return([ffprobe_csv, '', ok_status])

      result = described_class.detect_audio_tracks('test.mp4')

      expect(result).to eq([
        { index: 0, stream_index: 1, channels: 6, codec: 'ac3' },
        { index: 1, stream_index: 2, channels: 2, codec: 'aac' }
      ])
    end

    it 'returns a default track when ffprobe fails' do
      allow(Open3).to receive(:capture3).and_return(['', 'err', fail_status])

      result = described_class.detect_audio_tracks('bad.mp4')
      expect(result).to eq([{ index: 0, channels: 2, codec: 'unknown' }])
    end
  end

  describe '.detect_audio_channels' do
    it 'returns first stream channel count from ffprobe output' do
      allow(Open3).to receive(:capture3).and_return(["6\n", '', ok_status])

      expect(described_class.detect_audio_channels('test.mp4')).to eq(6)
    end
  end

  describe '.parse_loudnorm_json' do
    it 'raises a clear error when no loudnorm json is present' do
      expect { described_class.send(:parse_loudnorm_json, 'no json here') }
        .to raise_error(Neutraliser::FFmpegError, /loudnorm JSON not found/)
    end
  end
end
