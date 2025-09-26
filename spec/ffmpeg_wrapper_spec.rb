require 'spec_helper'
require 'json'
require 'tempfile'

RSpec.describe Neutraliser::FFmpegWrapper do
  describe '.measure_loudness' do
    let(:sample_json_output) do
      {
        "input_i" => "-18.5",
        "input_tp" => "-2.1",
        "input_lra" => "8.3",
        "input_thresh" => "-28.9",
        "target_offset" => "1.5"
      }
    end

    let(:stderr_with_json) do
      <<~STDERR
        [Parsed_loudnorm_0 @ 0x12345678]
        {
          "input_i" : "-18.5",
          "input_tp" : "-2.1",
          "input_lra" : "8.3",
          "input_thresh" : "-28.9",
          "target_offset" : "1.5"
        }
      STDERR
    end

    before do
      allow(Open3).to receive(:capture3).and_return(['', stderr_with_json, double(success?: true)])
    end

    it 'executes ffmpeg with correct loudnorm parameters' do
      described_class.measure_loudness('test.mp4', target_i: -20.0, target_tp: -1.5, target_lra: 12.0)

      expect(Open3).to have_received(:capture3).with(
        'ffmpeg', '-hide_banner', '-nostats', '-i', 'test.mp4',
        '-map', 'a:0',
        '-af', 'loudnorm=I=-20.0:TP=-1.5:LRA=12.0:print_format=json',
        '-f', 'null', '-'
      )
    end

    it 'parses loudnorm JSON output correctly' do
      result = described_class.measure_loudness('test.mp4')

      expect(result).to eq(sample_json_output)
    end

    context 'when ffmpeg command fails' do
      before do
        allow(Open3).to receive(:capture3).and_return(['', 'error output', double(success?: false)])
      end

      it 'raises FFmpegError with stderr content' do
        expect {
          described_class.measure_loudness('nonexistent.mp4')
        }.to raise_error(Neutraliser::FFmpegError, /error output/)
      end
    end

    context 'when JSON parsing fails' do
      before do
        allow(Open3).to receive(:capture3).and_return(['', 'invalid json', double(success?: true)])
      end

      it 'raises FFmpegError with parsing message' do
        expect {
          described_class.measure_loudness('test.mp4')
        }.to raise_error(Neutraliser::FFmpegError, /Failed to parse loudnorm JSON/)
      end
    end
  end

  describe '.apply_normalization' do
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

    before do
      allow(Open3).to receive(:capture3).and_return(['', '', double(success?: true)])
    end

    it 'executes ffmpeg with correct two-pass loudnorm parameters' do
      described_class.apply_normalization('input.mp4', 'output.mp4', measured_data, profile)

      expect(Open3).to have_received(:capture3).with(
        'ffmpeg', '-hide_banner', '-nostats', '-i', 'input.mp4',
        '-map', '0',
        '-c:v', 'copy',
        '-c:s', 'copy',
        '-c:a', 'aac',
        '-b:a', '256k',
        '-af', "loudnorm=I=-20.0:TP=-1.5:LRA=12.0:measured_I=-18.5:measured_TP=-2.1:measured_LRA=8.3:measured_thresh=-28.9:offset=1.5:print_format=json",
        '-y', 'output.mp4'
      )
    end

    context 'when ffmpeg command fails' do
      before do
        allow(Open3).to receive(:capture3).and_return(['', 'normalization failed', double(success?: false)])
      end

      it 'raises FFmpegError with stderr content' do
        expect {
          described_class.apply_normalization('input.mp4', 'output.mp4', measured_data, profile)
        }.to raise_error(Neutraliser::FFmpegError, /normalization failed/)
      end
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
    let(:audio_tracks) do
      [
        { index: 0, codec: 'ac3', channels: 6 },
        { index: 1, codec: 'aac', channels: 2 }
      ]
    end

    before do
      allow(Open3).to receive(:capture3).and_return(['', '', double(success?: true)])
    end

    context 'with 5.1+ surround audio' do
      it 'uses AC-3 codec for primary track' do
        described_class.apply_normalization_with_multiple_tracks(
          'input.mp4', 'output.mp4', measured_data, audio_tracks, profile
        )

        expect(Open3).to have_received(:capture3) do |*args|
          expect(args).to include('-c:a:0', 'ac3', '-b:a:0', '640k')
        end
      end
    end

    context 'with stereo audio' do
      let(:audio_tracks) { [{ index: 0, codec: 'aac', channels: 2 }] }

      it 'uses AAC codec for primary track' do
        described_class.apply_normalization_with_multiple_tracks(
          'input.mp4', 'output.mp4', measured_data, audio_tracks, profile
        )

        expect(Open3).to have_received(:capture3) do |*args|
          expect(args).to include('-c:a:0', 'aac', '-b:a:0', '256k')
        end
      end
    end
  end

  describe '.detect_audio_tracks' do
    let(:ffprobe_output) do
      {
        'streams' => [
          {
            'index' => 0,
            'codec_type' => 'video',
            'codec_name' => 'h264'
          },
          {
            'index' => 1,
            'codec_type' => 'audio',
            'codec_name' => 'ac3',
            'channels' => 6
          },
          {
            'index' => 2,
            'codec_type' => 'audio',
            'codec_name' => 'aac',
            'channels' => 2
          }
        ]
      }.to_json
    end

    before do
      allow(Open3).to receive(:capture3).and_return([ffprobe_output, '', double(success?: true)])
    end

    it 'detects all audio tracks correctly' do
      result = described_class.detect_audio_tracks('test.mp4')

      expect(result).to eq([
        { index: 1, codec: 'ac3', channels: 6 },
        { index: 2, codec: 'aac', channels: 2 }
      ])
    end

    it 'calls ffprobe with correct parameters' do
      described_class.detect_audio_tracks('test.mp4')

      expect(Open3).to have_received(:capture3).with(
        'ffprobe', '-v', 'quiet', '-print_format', 'json', '-show_streams', 'test.mp4'
      )
    end
  end

  describe '.detect_audio_channels' do
    let(:ffprobe_output) do
      {
        'streams' => [
          {
            'index' => 0,
            'codec_type' => 'audio',
            'codec_name' => 'ac3',
            'channels' => 6
          }
        ]
      }.to_json
    end

    before do
      allow(Open3).to receive(:capture3).and_return([ffprobe_output, '', double(success?: true)])
    end

    it 'returns channel count for first audio stream' do
      result = described_class.detect_audio_channels('test.mp4')
      expect(result).to eq(6)
    end

    context 'when no audio stream exists' do
      let(:ffprobe_output) do
        { 'streams' => [] }.to_json
      end

      it 'returns nil' do
        result = described_class.detect_audio_channels('test.mp4')
        expect(result).to be_nil
      end
    end
  end

  describe '.parse_loudnorm_json' do
    it 'extracts JSON from stderr output correctly' do
      stderr = <<~STDERR
        [Parsed_loudnorm_0 @ 0x12345678]
        {
          "input_i" : "-18.5",
          "input_tp" : "-2.1"
        }
        Some other output
      STDERR

      result = described_class.send(:parse_loudnorm_json, stderr)
      expect(result).to eq({ 'input_i' => '-18.5', 'input_tp' => '-2.1' })
    end

    it 'handles malformed JSON gracefully' do
      stderr = "No JSON here"

      expect {
        described_class.send(:parse_loudnorm_json, stderr)
      }.to raise_error(Neutraliser::FFmpegError, /Failed to parse loudnorm JSON/)
    end
  end
end