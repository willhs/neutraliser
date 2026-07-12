require 'spec_helper'
require 'shellwords'

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
      allow(described_class).to receive(:execute_with_timeout).and_return(['', stderr, ok_status])

      result = described_class.measure_loudness('test.mp4', target_i: -20.0, target_tp: -1.5, target_lra: 12.0)

      expect(described_class).to have_received(:execute_with_timeout).with(
        [
          'ffmpeg', '-hide_banner', '-nostats', '-i', 'test.mp4',
          '-map', 'a:0',
          '-af', 'loudnorm=I=-20.0:TP=-1.5:LRA=12.0:print_format=json',
          '-f', 'null', '-'
        ],
        described_class::ANALYSIS_TIMEOUT,
        'Loudness measurement'
      )
      expect(result['input_i']).to eq('-18.5')
    end

    it 'raises FFmpegError including stderr when command fails' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'boom', fail_status])

      expect { described_class.measure_loudness('missing.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

  describe '.quick_loudness_sample' do
    it 'returns nil when file is too short for meaningful sample' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['40', '', ok_status])

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
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      result = described_class.apply_normalization_with_multiple_tracks('in.mkv', 'out.mkv', measured_data, tracks, profile)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('-c:a:0', 'ac3', '-b:a:0', '448k')
        expect(cmd).to include('-map', '0:a:1', '-c:a:1', 'copy')
        filter_arg = cmd[cmd.index('-filter_complex') + 1]
        expect(filter_arg).to include('aresample=48000')
      end
      expect(result[:encoder]).to eq('ac3')
      expect(result[:bitrate]).to eq(448_000)
      expect(result[:normalization_type]).to eq('Linear')
    end

    it 'maps per-stream metadata from the primary track onto the normalised output stream' do
      tracks = [
        { index: 0, channels: 6, codec: 'ac3', bit_rate: 448_000, sample_rate: 48_000 },
        { index: 1, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
      ]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      described_class.apply_normalization_with_multiple_tracks('in.mkv', 'out.mkv', measured_data, tracks, profile)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('-map_metadata:s:a:0', '0:s:a:0')
      end
    end

    it 'maps per-stream metadata back to the primary track source audio index, not always 0' do
      # Simulates a primary track that is not the first audio stream in the source file.
      tracks = [
        { index: 2, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
      ]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      described_class.apply_normalization_with_multiple_tracks('in.mkv', 'out.mkv', measured_data, tracks, profile)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('-map_metadata:s:a:0', '0:s:a:2')
      end
    end

    it 'records Dynamic normalization type when loudnorm falls back silently' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Dynamic', ok_status])

      result = described_class.apply_normalization_with_multiple_tracks('in.mp4', 'out.mp4', measured_data, tracks, profile)

      expect(result[:normalization_type]).to eq('Dynamic')
    end

    it 'never engages dynamic compression in linear_only mode, regardless of ffmpeg output' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Dynamic', ok_status])

      result = described_class.apply_normalization_with_multiple_tracks('in.mp4', 'out.mp4', measured_data, tracks, profile, linear_only: true)

      expect(result[:normalization_type]).to eq('Linear')
      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        filter_arg = cmd[cmd.index('-filter_complex') + 1]
        expect(filter_arg).to include('volume=')
        expect(filter_arg).not_to include('loudnorm')
      end
    end
  end

  describe '.apply_normalization_single_pass' do
    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0, name: 'livingroom' } }

    it 'builds a loudnorm filter without measured values' do
      allow(described_class).to receive(:detect_audio_tracks).and_return(
        [{ index: 0, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 48_000 }]
      )
      allow(described_class).to receive(:execute_with_progress)

      described_class.apply_normalization_single_pass('/in.mp4', '/out.mp4', nil, profile)

      expect(described_class).to have_received(:execute_with_progress) do |cmd|
        filter_arg = cmd[cmd.index('-filter_complex') + 1]
        expect(filter_arg).to include('loudnorm=I=-20.0:TP=-1.5:LRA=12.0')
        expect(filter_arg).not_to include('measured_I')
        expect(filter_arg).not_to include('linear=true')
      end
    end

    it 'returns a codec decision hash' do
      allow(described_class).to receive(:detect_audio_tracks).and_return(
        [{ index: 0, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 48_000 }]
      )
      allow(described_class).to receive(:execute_with_progress)

      result = described_class.apply_normalization_single_pass('/in.mp4', '/out.mp4', nil, profile)

      expect(result).to include(encoder: 'aac', source_codec: 'aac')
    end
  end

  describe '.detect_audio_tracks' do
    it 'parses ffprobe json output by field name, not positional order' do
      # ffprobe emits fields in canonical order (index,codec_name,sample_rate,channels,bit_rate)
      # regardless of the order requested in -show_entries — parsing must be name-based.
      ffprobe_json = {
        streams: [
          { index: 1, codec_name: 'ac3', sample_rate: '48000', channels: 6, bit_rate: '640000' },
          { index: 2, codec_name: 'aac', sample_rate: '44100', channels: 2, bit_rate: '256000' }
        ]
      }.to_json
      allow(described_class).to receive(:execute_with_timeout).and_return([ffprobe_json, '', ok_status])

      result = described_class.detect_audio_tracks('test.mkv')

      expect(described_class).to have_received(:execute_with_timeout).with(
        array_including('-of', 'json'), described_class::PROBE_TIMEOUT, 'Audio track detection'
      )
      expect(result).to eq([
        { index: 0, stream_index: 1, channels: 6, codec: 'ac3', bit_rate: 640000, sample_rate: 48000 },
        { index: 1, stream_index: 2, channels: 2, codec: 'aac', bit_rate: 256000, sample_rate: 44100 }
      ])
    end

    it 'returns a default track when ffprobe fails' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'err', fail_status])

      result = described_class.detect_audio_tracks('bad.mp4')
      expect(result).to eq([{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }])
    end

    it 'treats an absent bit_rate field as nil rather than defaulting to stereo/FLAC' do
      # MKV streams commonly omit bit_rate entirely (not "N/A") when unknown.
      ffprobe_json = {
        streams: [
          { index: 1, codec_name: 'flac', sample_rate: '48000', channels: 6 }
        ]
      }.to_json
      allow(described_class).to receive(:execute_with_timeout).and_return([ffprobe_json, '', ok_status])

      result = described_class.detect_audio_tracks('test.mkv')

      expect(result.first[:codec]).to eq('flac')
      expect(result.first[:channels]).to eq(6)
      expect(result.first[:bit_rate]).to be_nil
      expect(result.first[:sample_rate]).to eq(48000)
    end

    it 'returns a default track when ffprobe emits unparseable json' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['not json', '', ok_status])

      result = described_class.detect_audio_tracks('bad.mkv')
      expect(result).to eq([{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }])
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

    it 'round-trips AAC-in-MKV as AAC instead of falling back to FLAC' do
      # Regression: with correct field-name parsing, an AAC source in an MKV
      # container must map to the AAC encoder per ADR-0001 priority — not the
      # MKV lossless-fallback (FLAC) that a broken codec parse would trigger.
      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: 128_000), 'out.mkv')
      expect(result[:encoder]).to eq('aac')
      expect(result[:lossless_output]).to eq(false)
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

    it 'uses the floor when source bitrate is unknown and no input_path is given for estimation' do
      expect(described_class).not_to receive(:execute_with_timeout)
      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: nil), 'out.mp4')
      expect(result[:bitrate]).to eq(128_000)
    end

    it 'estimates bitrate from the container BPS tag when stream bit_rate is N/A (MKV)' do
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('stream_tags=BPS'), described_class::PROBE_TIMEOUT, anything)
        .and_return(["192000\n", '', ok_status])

      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: nil), 'out.mkv', 'in.mkv')

      expect(result[:encoder]).to eq('aac')
      expect(result[:bitrate]).to eq(192_000)
    end

    it 'falls back to packet-size sampling when no BPS tag is present' do
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('stream_tags=BPS'), described_class::PROBE_TIMEOUT, anything)
        .and_return(['N/A', '', ok_status])
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('packet=size'), described_class::PROBE_TIMEOUT, anything)
        .and_return(["24000\n24000\n24000\n24000\n24000\n", '', ok_status])

      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: nil), 'out.mkv', 'in.mkv')

      # 5 packets * 24000 bytes = 120000 bytes over the 10s default sample window
      # => (120000 * 8) / 10 = 96000 bps, floored to the AAC stereo minimum (128000)
      expect(result[:bitrate]).to eq(128_000)
    end

    it 'uses an estimate above the floor as the source bitrate for the floor/cap logic' do
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('stream_tags=BPS'), described_class::PROBE_TIMEOUT, anything)
        .and_return(['N/A', '', ok_status])
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('packet=size'), described_class::PROBE_TIMEOUT, anything)
        .and_return(["48000\n48000\n48000\n48000\n48000\n", '', ok_status])

      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: nil), 'out.mkv', 'in.mkv')

      # 5 packets * 48000 bytes = 240000 bytes over the 10s default sample window
      # => (240000 * 8) / 10 = 192000 bps, above the 128000 floor
      expect(result[:bitrate]).to eq(192_000)
    end

    it 'falls back to the floor when neither the BPS tag nor packet sampling yield a usable number' do
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('stream_tags=BPS'), described_class::PROBE_TIMEOUT, anything)
        .and_return(['N/A', '', ok_status])
      allow(described_class).to receive(:execute_with_timeout)
        .with(array_including('packet=size'), described_class::PROBE_TIMEOUT, anything)
        .and_return(['', '', fail_status])

      result = described_class.send(:select_output_codec, make_track(codec: 'aac', bit_rate: nil), 'out.mkv', 'in.mkv')

      expect(result[:bitrate]).to eq(128_000)
    end
  end

  describe '.parse_loudnorm_json' do
    it 'raises a clear error when no loudnorm json is present' do
      expect { described_class.send(:parse_loudnorm_json, 'no json here') }
        .to raise_error(Neutraliser::FFmpegError, /loudnorm JSON not found/)
    end
  end

  describe '.parse_normalization_type' do
    it 'extracts Linear from the loudnorm summary output' do
      output = "Input Integrated:    -18.5 LUFS\nNormalization Type:   Linear\n"
      expect(described_class.send(:parse_normalization_type, output)).to eq('Linear')
    end

    it 'extracts Dynamic from the loudnorm summary output' do
      output = "Input Integrated:    -18.5 LUFS\nNormalization Type:   Dynamic\n"
      expect(described_class.send(:parse_normalization_type, output)).to eq('Dynamic')
    end

    it 'returns nil when no normalization type line is present' do
      expect(described_class.send(:parse_normalization_type, 'no summary here')).to be_nil
    end

    it 'returns nil for nil output' do
      expect(described_class.send(:parse_normalization_type, nil)).to be_nil
    end
  end

  describe '.capped_linear_gain' do
    let(:measured) { { 'input_i' => '-25.0', 'input_tp' => '-20.0' } }

    it 'uses the full gain needed to reach target loudness when peak headroom allows it' do
      gain = described_class.send(:capped_linear_gain, measured, -20.0, -1.5)
      expect(gain).to eq(5.0) # -20.0 - (-25.0)
    end

    it 'caps gain so the resulting true peak never exceeds target_tp' do
      # Desired gain (13.0) would push -3.0 dBTP up to +10.0 dBTP — way past -1.5.
      # Gain must be capped to the max safe headroom (-1.5 - (-3.0) = 1.5 dB),
      # landing the file shy of target_i instead of engaging dynamic compression.
      peaky_measured = { 'input_i' => '-33.0', 'input_tp' => '-3.0' }
      gain = described_class.send(:capped_linear_gain, peaky_measured, -20.0, -1.5)
      expect(gain).to eq(1.5)
    end
  end

  describe 'linear_only sample rate pinning' do
    it 'pins output sample rate to source when no measured peak headroom issue exists' do
      measured = { 'input_i' => '-25.0', 'input_tp' => '-10.0' }
      filter, forced_type = described_class.send(
        :build_audio_filter, measured, -20.0, -1.5, 12.0, 48_000, linear_only: true
      )

      expect(filter).to eq('volume=5.00dB,aresample=48000')
      expect(forced_type).to eq('Linear')
    end

    it 'omits aresample when source sample rate is unknown' do
      measured = { 'input_i' => '-25.0', 'input_tp' => '-10.0' }
      filter, = described_class.send(
        :build_audio_filter, measured, -20.0, -1.5, 12.0, nil, linear_only: true
      )

      expect(filter).not_to include('aresample')
    end

    it 'pins aresample on the loudnorm (non-linear-only) path too, to prevent the 192kHz leak' do
      measured = { 'input_i' => '-25.0', 'input_tp' => '-10.0', 'input_lra' => '8.0', 'input_thresh' => '-30.0', 'target_offset' => '0.0' }
      filter, forced_type = described_class.send(
        :build_audio_filter, measured, -20.0, -1.5, 12.0, 48_000, linear_only: false
      )

      expect(filter).to include('loudnorm=')
      expect(filter).to end_with('aresample=48000')
      expect(forced_type).to be_nil
    end
  end

  describe 'integration: metadata + bitrate preservation on a real MKV fixture' do
    def ffprobe_stream(path, select_streams, show_entries)
      json = `ffprobe -v error -select_streams #{select_streams} -show_entries #{show_entries} -of json #{path.shellescape} 2>/dev/null`
      JSON.parse(json)['streams'].first || {}
    end

    before do
      skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
    end

    it 'keeps language/title tags on the normalised primary track and copied secondary track, and avoids the bitrate floor for an MKV source with no reported bit_rate' do
      Dir.mktmpdir do |dir|
        input = File.join(dir, 'input.mkv')
        output = File.join(dir, 'output.mkv')

        # 12s so the 10s packet-sampling window reflects real throughput; noise
        # sources give AAC genuine entropy to encode against (unlike silence/tones).
        fixture_cmd = [
          'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
          '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=12',
          '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=12:sample_rate=48000',
          '-f', 'lavfi', '-i', 'anoisesrc=color=blue:duration=12:sample_rate=48000',
          '-map', '0:v', '-map', '1:a', '-map', '2:a',
          '-c:v', 'libx264', '-preset', 'ultrafast',
          '-c:a:0', 'aac', '-ac:a:0', '2', '-b:a:0', '256k',
          '-metadata:s:a:0', 'language=eng', '-metadata:s:a:0', 'title=English Track',
          '-c:a:1', 'aac', '-ac:a:1', '2', '-b:a:1', '128k',
          '-metadata:s:a:1', 'language=jpn', '-metadata:s:a:1', 'title=Japanese Track',
          input
        ]
        raise 'fixture generation failed' unless system(*fixture_cmd)

        audio_tracks = described_class.detect_audio_tracks(input)
        expect(audio_tracks.map { |t| t[:bit_rate] }).to all(be_nil) # MKV: no reported bit_rate, forces estimation

        profile = { lufs: -20.0, tp: -1.5, lra: 12.0 }
        result = described_class.apply_normalization_single_pass(input, output, audio_tracks, profile)

        primary_tags = ffprobe_stream(output, 'a:0', 'stream_tags=language,title')['tags']
        expect(primary_tags['language']).to eq('eng')
        expect(primary_tags['title']).to eq('English Track')

        secondary_tags = ffprobe_stream(output, 'a:1', 'stream_tags=language,title')['tags']
        expect(secondary_tags['language']).to eq('jpn')
        expect(secondary_tags['title']).to eq('Japanese Track')

        # Estimated from packet sampling (no BPS tag from ffmpeg's own muxer) —
        # must land near the real ~256k source, not the 128k AAC stereo floor.
        expect(result[:bitrate]).to be > 128_000
        expect(result[:source_bitrate]).to be > 128_000
      end
    end
  end
end
