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
          '-map', '0:a:0',
          '-af', 'loudnorm=I=-20.0:TP=-1.5:LRA=12.0:print_format=json',
          '-f', 'null', '-'
        ],
        described_class::ANALYSIS_TIMEOUT,
        'Loudness measurement'
      )
      expect(result).to be_a(Neutraliser::Measurement)
      expect(result.input_i).to eq(-18.5)
    end

    it 'raises FFmpegError including stderr when command fails' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'boom', fail_status])

      expect { described_class.measure_loudness('missing.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end

  describe '.probe_duration' do
    it 'returns the parsed duration on success' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['12.3', '', ok_status])

      expect(described_class.probe_duration('test.mp4')).to eq(12.3)
      expect(described_class).to have_received(:execute_with_timeout).with(
        array_including('ffprobe', 'format=duration'), described_class::PROBE_TIMEOUT, 'Duration probe'
      )
    end

    it 'returns nil when ffprobe reports failure' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'bad', fail_status])

      expect(described_class.probe_duration('bad.mp4')).to be_nil
    end

    it 'returns nil when duration is not a positive number' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', '', ok_status])

      expect(described_class.probe_duration('empty.mp4')).to be_nil
    end

    it 'propagates a timeout so callers can tell it apart from a bad probe result' do
      allow(described_class).to receive(:execute_with_timeout).and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      expect { described_class.probe_duration('slow.mp4') }.to raise_error(Neutraliser::FFmpegTimeoutError)
    end
  end

  describe '.quick_loudness_sample' do
    it 'returns nil when file is too short for meaningful sample' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['40', '', ok_status])

      result = described_class.quick_loudness_sample('short.mp4', duration: 30)
      expect(result).to be_nil
    end

    it 'returns nil (rather than raising) when the duration probe times out' do
      allow(described_class).to receive(:probe_duration).and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      expect(described_class.quick_loudness_sample('slow.mp4')).to be_nil
    end
  end

  describe 'public surface' do
    it 'exposes only the intended ~8 methods' do
      expect(described_class.singleton_methods(false)).to contain_exactly(
        :measure_loudness,
        :probe_duration,
        :quick_loudness_sample,
        :apply_normalization,
        :apply_normalization_single_pass,
        :detect_audio_tracks,
        :read_stamp,
        :primary_audio_track,
        :primary_audio_index,
        :probe_audio_profile_mid_file,
        :stream_counts,
        :unsupported_subtitles,
        :codec_change,
        :output_audio_count
      )
    end
  end

  describe '.apply_normalization' do
    let(:measured_data) do
      Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-18.5',
        'input_tp' => '-2.1',
        'input_lra' => '8.3',
        'input_thresh' => '-28.9',
        'target_offset' => '1.5'
      )
    end

    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0 } }

    before do
      allow(described_class).to receive(:stream_counts).and_return(video: 0, subtitle: 0)
      allow(described_class).to receive(:output_container) { |_input, output| File.extname(output).downcase }
    end

    it 'uses source-matched codec for primary track and copies additional tracks' do
      tracks = [
        { index: 0, channels: 6, codec: 'ac3', bit_rate: 448_000, sample_rate: 48_000 },
        { index: 1, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
      ]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      result = described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile, audio_tracks: tracks)

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

    describe 'default-disposition primary' do
      let(:tracks) do
        [
          { index: 0, channels: 2, codec: 'aac', title: 'Commentary', bit_rate: 128_000, sample_rate: 44_100, default: false },
          { index: 1, channels: 6, codec: 'ac3', title: 'English', bit_rate: 448_000, sample_rate: 48_000, default: true },
          { index: 2, channels: 2, codec: 'aac', title: 'French', bit_rate: 128_000, sample_rate: 48_000, default: false }
        ]
      end

      def run(audio_tracks, **opts)
        allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])
        described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile.merge(name: 'livingroom'),
                                            audio_tracks: audio_tracks, **opts)
        captured = nil
        expect(described_class).to have_received(:execute_with_timeout) { |cmd, *_| captured ||= cmd }
        captured
      end

      it 'normalises the default track in place and copies the others around it' do
        cmd = run(tracks)
        pairs = cmd.each_cons(2).to_a
        expect(cmd[cmd.index('-filter_complex') + 1]).to start_with('[0:a:1]')
        maps = cmd.each_cons(2).select { |a, _| a == '-map' }.map(&:last)
        expect(maps).to eq(['0:v', '0:a:0', '[norm]', '0:a:2', '0:s?'])
        expect(pairs).to include(['-c:a:0', 'copy'], ['-c:a:1', 'ac3'], ['-b:a:1', '448k'], ['-c:a:2', 'copy'])
        expect(pairs).to include(['-map_metadata:s:a:0', '0:s:a:0'], ['-map_metadata:s:a:1', '0:s:a:1'],
                                 ['-map_metadata:s:a:2', '0:s:a:2'])
        expect(pairs).to include(['-metadata:s:a:1', a_string_starting_with('NEUTRALISER_')])
        expect(pairs).to include(['-disposition:a:1', 'default'])
        expect(pairs).not_to include(['-c:a:0', 'ac3'])
      end

      it 'puts the kept original right after the normalised track and shifts later tracks' do
        cmd = run(tracks, keep_original: true)
        pairs = cmd.each_cons(2).to_a
        maps = pairs.select { |a, _| a == '-map' }.map(&:last)
        expect(maps).to eq(['0:v', '0:a:0', '[norm]', '0:a:1', '0:a:2', '0:s?'])
        expect(pairs).to include(['-c:a:2', 'copy'], ['-c:a:3', 'copy'])
        expect(pairs).to include(['-map_metadata:s:a:2', '0:s:a:1'], ['-map_metadata:s:a:3', '0:s:a:2'])
        expect(pairs).to include(['-disposition:a:1', 'default'], ['-disposition:a:2', '0'])
      end

      it 'falls back to the first track when none is flagged default' do
        cmd = run(tracks.map { |t| t.merge(default: false) })
        expect(cmd[cmd.index('-filter_complex') + 1]).to start_with('[0:a:0]')
        expect(cmd.each_cons(2).to_a).not_to include(['-disposition:a:0', 'default'])
      end
    end

    describe 'keep_original' do
      let(:tracks) do
        [
          { index: 0, channels: 6, codec: 'ac3', title: 'English 5.1', bit_rate: 448_000, sample_rate: 48_000 },
          { index: 1, channels: 2, codec: 'aac', title: 'Commentary', bit_rate: 256_000, sample_rate: 44_100 }
        ]
      end

      def run(audio_tracks, **opts)
        allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])
        described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile.merge(name: 'livingroom'),
                                            audio_tracks: audio_tracks, **opts)
        captured = nil
        expect(described_class).to have_received(:execute_with_timeout) { |cmd, *_| captured ||= cmd }
        captured
      end

      it 'is off by default: no extra track' do
        cmd = run(tracks)
        expect(cmd).not_to include('-disposition:a:1')
        expect(cmd.each_cons(2).count { |a, b| a == '-map' && b == '0:a:0' }).to eq(0)
      end

      it 'copies the original after the normalised track and shifts the other tracks' do
        cmd = run(tracks, keep_original: true)
        pairs = cmd.each_cons(2).to_a
        expect(pairs).to include(['-map', '0:a:0'], ['-c:a:1', 'copy'], ['-map', '0:a:1'], ['-c:a:2', 'copy'])
        expect(pairs).to include(['-map_metadata:s:a:0', '0:s:a:0'], ['-map_metadata:s:a:1', '0:s:a:0'],
                                 ['-map_metadata:s:a:2', '0:s:a:1'])
        expect(pairs).to include(['-metadata:s:a:1', 'title=English 5.1 (original, not normalised)'],
                                 ['-disposition:a:0', 'default'], ['-disposition:a:1', '0'])
      end

      it 'does not add a second copy when a kept original is already present' do
        kept = tracks + [{ index: 2, channels: 6, codec: 'ac3', title: 'English 5.1 (original, not normalised)' }]
        kept = [tracks[0], kept.last, tracks[1]].each_with_index.map { |t, i| t.merge(index: i) }
        cmd = run(kept, keep_original: true)
        expect(cmd).not_to include('-disposition:a:1')
        expect(cmd.each_cons(2)).to include(['-c:a:1', 'copy'], ['-c:a:2', 'copy'])
      end
    end

    it 'maps per-stream metadata from the primary track onto the normalised output stream' do
      tracks = [
        { index: 0, channels: 6, codec: 'ac3', bit_rate: 448_000, sample_rate: 48_000 },
        { index: 1, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 44_100 }
      ]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile, audio_tracks: tracks)

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

      described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile, audio_tracks: tracks)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('-map_metadata:s:a:0', '0:s:a:2')
      end
    end

    it 'maps per-stream metadata for every video and subtitle stream, not just audio' do
      # Issuing any stream-scoped -map_metadata disables ffmpeg's default
      # implicit per-stream metadata copy for the whole command, so video
      # and subtitle streams need their own explicit mapping too, or their
      # language/title tags come out empty despite being plain stream-copies.
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:stream_counts).and_return(video: 2, subtitle: 3)
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile, audio_tracks: tracks)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('-map_metadata:s:v:0', '0:s:v:0', '-map_metadata:s:v:1', '0:s:v:1')
        expect(cmd).to include(
          '-map_metadata:s:s:0', '0:s:s:0',
          '-map_metadata:s:s:1', '0:s:s:1',
          '-map_metadata:s:s:2', '0:s:s:2'
        )
      end
    end

    it 'records Dynamic normalization type when loudnorm falls back silently, and corrects the stamp' do
      # measured_data fits loudnorm's linear rule, so linear is predicted and
      # written; ffmpeg then reports Dynamic, so the tags are rewritten.
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Dynamic', ok_status])
      allow(FileUtils).to receive(:mv)

      result = described_class.apply_normalization('in.mp4', 'out.mp4', measured_data, profile.merge(name: 'livingroom'),
                                                   audio_tracks: tracks, allow_dynamic: true)

      expect(result[:normalization_type]).to eq('Dynamic')
      expect(described_class).to have_received(:execute_with_timeout).with(
        array_including('-map', '0', '-c', 'copy', 'NEUTRALISER_MODE=dynamic', 'NEUTRALISER_GAIN_DB='),
        described_class::NORMALIZATION_TIMEOUT, 'Restamp'
      )
      expect(FileUtils).to have_received(:mv).with('./.restamp-out.mp4', 'out.mp4')
    end

    it 'does not remux when loudnorm does what was predicted' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Linear', ok_status])

      described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile.merge(name: 'livingroom'),
                                          audio_tracks: tracks, allow_dynamic: true)

      expect(described_class).to have_received(:execute_with_timeout).once
      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('NEUTRALISER_MODE=linear', 'NEUTRALISER_GAIN_DB=-1.50')
      end
    end

    it 'predicts dynamic up front when the source LRA exceeds the target' do
      wide = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => '-24', 'input_tp' => '-10', 'input_lra' => '20', 'input_thresh' => '-34', 'target_offset' => '0'
      )
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Dynamic', ok_status])

      described_class.apply_normalization('in.mkv', 'out.mkv', wide, profile.merge(name: 'livingroom'),
                                          audio_tracks: tracks, allow_dynamic: true)

      expect(described_class).to have_received(:execute_with_timeout).once
      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd).to include('NEUTRALISER_MODE=dynamic', 'NEUTRALISER_GAIN_DB=')
      end
    end

    it 'stamps the normalised stream and the container, after the existing metadata mappings' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', '', ok_status])

      described_class.apply_normalization('in.mkv', 'out.mkv', measured_data, profile.merge(name: 'livingroom'),
                                          audio_tracks: tracks)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd.each_cons(2).to_a).to include(
          ['-metadata:s:a:0', 'NEUTRALISER_PROFILE=livingroom'], ['-metadata', 'NEUTRALISER_PROFILE=livingroom'],
          ['-metadata:s:a:0', 'NEUTRALISER_MODE=linear'], ['-metadata:s:a:0', 'NEUTRALISER_GAIN_DB=-1.50'],
          ['-metadata:s:a:0', 'NEUTRALISER_SOURCE_CODEC=aac'], ['-metadata:s:a:0', 'NEUTRALISER_SOURCE_BITRATE=128000'],
          ['-metadata:s:a:0', 'NEUTRALISER_MEASURED_I=-18.50'], ['-metadata:s:a:0', "NEUTRALISER_VERSION=#{Neutraliser::VERSION}"]
        )
        expect(cmd).to include('-map_metadata:s:a:0', '0:s:a:0')
        expect(cmd.index('-metadata:s:a:0')).to be > cmd.index('-map_metadata:s:a:0')
        expect(cmd.last).to eq('out.mkv')
        expect(cmd).not_to include('-movflags')
      end
    end

    it 'turns on use_metadata_tags for MP4 so the container-level stamp survives' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', '', ok_status])

      described_class.apply_normalization('in.mp4', 'out.mp4', measured_data, profile.merge(name: 'livingroom'),
                                          audio_tracks: tracks)

      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        expect(cmd.each_cons(2).to_a).to include(['-movflags', '+use_metadata_tags'])
      end
    end

    it 'never engages dynamic compression by default, regardless of ffmpeg output' do
      tracks = [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }]
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'Normalization Type:   Dynamic', ok_status])

      result = described_class.apply_normalization('in.mp4', 'out.mp4', measured_data, profile, audio_tracks: tracks)

      expect(result[:normalization_type]).to eq('Linear')
      expect(described_class).to have_received(:execute_with_timeout) do |cmd, *_rest|
        filter_arg = cmd[cmd.index('-filter_complex') + 1]
        expect(filter_arg).to include('volume=')
        expect(filter_arg).not_to include('loudnorm')
      end
    end
  end

  describe '.apply_normalization shortfall' do
    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0, name: 'livingroom' } }
    let(:ok_status) { instance_double(Process::Status, success?: true) }
    let(:tracks) { [{ index: 0, channels: 2, codec: 'aac', bit_rate: 128_000, sample_rate: 48_000 }] }

    before do
      allow(described_class).to receive_messages(stream_counts: { video: 0, subtitle: 0 },
                                                 execute_with_timeout: ['', '', ok_status])
    end

    it 'reports how far a peak-capped file lands short of target' do
      peaky = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-30.0', 'input_tp' => '-3.0', 'input_lra' => '5', 'input_thresh' => '-40', 'target_offset' => '0')

      result = described_class.apply_normalization('in.mp4', 'out.mp4', peaky, profile, audio_tracks: tracks)

      expect(result[:shortfall_lu]).to eq(8.5)
    end

    it 'reports no shortfall when the full gain fits under the peak ceiling' do
      safe = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-25.0', 'input_tp' => '-10.0', 'input_lra' => '5', 'input_thresh' => '-40', 'target_offset' => '0')

      result = described_class.apply_normalization('in.mp4', 'out.mp4', safe, profile, audio_tracks: tracks)

      expect(result).not_to have_key(:shortfall_lu)
    end
  end

  describe '.apply_normalization_single_pass' do
    let(:profile) { { lufs: -20.0, tp: -1.5, lra: 12.0, name: 'livingroom' } }

    before do
      allow(described_class).to receive(:stream_counts).and_return(video: 0, subtitle: 0)
    end

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

    it 'stamps the output as dynamic with no gain or measurement' do
      allow(described_class).to receive(:detect_audio_tracks).and_return(
        [{ index: 0, channels: 2, codec: 'aac', bit_rate: 256_000, sample_rate: 48_000 }]
      )
      allow(described_class).to receive(:execute_with_progress)

      described_class.apply_normalization_single_pass('/in.mp4', '/out.mp4', nil, profile)

      expect(described_class).to have_received(:execute_with_progress) do |cmd|
        expect(cmd).to include('NEUTRALISER_MODE=dynamic', 'NEUTRALISER_GAIN_DB=', 'NEUTRALISER_MEASURED_I=')
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

  describe '.read_stamp' do
    def probe_json(stream_tags: nil, format_tags: nil)
      JSON.generate(streams: [{ tags: stream_tags }.compact], format: { tags: format_tags }.compact)
    end

    it 'reads the stamp from the primary audio stream' do
      json = probe_json(stream_tags: { 'NEUTRALISER_PROFILE' => 'night', 'NEUTRALISER_MODE' => 'dynamic' },
                        format_tags: { 'NEUTRALISER_PROFILE' => 'livingroom' })
      allow(described_class).to receive(:execute_with_timeout).and_return([json, '', ok_status])

      stamp = described_class.read_stamp('in.mkv')

      expect(stamp).to have_attributes(profile: 'night', mode: 'dynamic')
    end

    it 'falls back to container tags (all MP4 keeps)' do
      json = probe_json(stream_tags: { 'language' => 'eng' },
                        format_tags: { 'NEUTRALISER_PROFILE' => 'livingroom', 'NEUTRALISER_GAIN_DB' => '3.20' })
      allow(described_class).to receive(:execute_with_timeout).and_return([json, '', ok_status])

      expect(described_class.read_stamp('in.mp4')).to have_attributes(profile: 'livingroom', gain_db: 3.2)
    end

    it 'is nil for an unstamped file or a failed probe' do
      allow(described_class).to receive(:execute_with_timeout).and_return([probe_json(stream_tags: { 'a' => 'b' }), '', ok_status])
      expect(described_class.read_stamp('plain.mkv')).to be_nil

      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'bad', fail_status])
      expect(described_class.read_stamp('bad.mkv')).to be_nil
    end
  end

  describe '.unsupported_subtitles' do
    it 'names subtitle streams ffmpeg has no codec for, with the Matroska codec ID' do
      stdout = JSON.generate(streams: [{ index: 2 }, { index: 3, codec_name: 'subrip' }, { index: 4 }])
      stderr = "[matroska,webm @ 0x1] Unknown/unsupported AVCodecID S_TEXT/WEBVTT.\n" \
               "[matroska,webm @ 0x1] Unknown/unsupported AVCodecID S_TEXT/FOO.\n"
      allow(described_class).to receive(:execute_with_timeout).and_return([stdout, stderr, ok_status])

      expect(described_class.unsupported_subtitles('episode.mkv'))
        .to eq(['stream 2 (S_TEXT/WEBVTT)', 'stream 4 (S_TEXT/FOO)'])
    end

    it 'returns nothing when every subtitle has a codec' do
      stdout = JSON.generate(streams: [{ index: 2, codec_name: 'hdmv_pgs_subtitle' }])
      allow(described_class).to receive(:execute_with_timeout).and_return([stdout, '', ok_status])

      expect(described_class.unsupported_subtitles('movie.mkv')).to eq([])
    end

    it 'is best effort: a failed probe blocks nothing' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'boom', fail_status])

      expect(described_class.unsupported_subtitles('movie.mkv')).to eq([])
    end
  end

  describe '.primary_audio_track' do
    it 'is the default-disposition track, else the first' do
      tracks = [{ index: 0 }, { index: 1, default: true }]
      expect(described_class.primary_audio_track(tracks)).to eq(index: 1, default: true)
      expect(described_class.primary_audio_track([{ index: 0 }, { index: 1 }])).to eq(index: 0)
    end

    it 'prefers the first English track over the first track when none is flagged default' do
      tracks = [{ index: 0, language: 'spa' }, { index: 1, language: 'fra' }, { index: 2, language: 'eng' }]
      expect(described_class.primary_audio_track(tracks)).to eq(index: 2, language: 'eng')
    end

    it 'lets the default flag beat the English fallback' do
      tracks = [{ index: 0, language: 'spa', default: true }, { index: 1, language: 'eng' }]
      expect(described_class.primary_audio_track(tracks)).to include(index: 0)
    end
  end

  describe '.codec_change' do
    def change(codec, out, **track)
      described_class.codec_change({ codec: codec, channels: 6, **track }, out)
    end

    it 'is nil when the codec re-encodes to itself in the container' do
      expect(change('aac', 'a.mkv')).to be_nil
      expect(change('eac3', 'a.mp4')).to be_nil
      expect(change('mp3', 'a.mkv')).to be_nil
    end

    it 'names the replacement encoder when the codec cannot be kept' do
      expect(change('dts', 'a.mkv')).to eq('flac')
      expect(change('truehd', 'a.mkv')).to eq('flac')
      expect(change('dts', 'a.mp4')).to eq('eac3')
      expect(change('flac', 'a.mp4')).to eq('eac3') # flac has no home in MP4
    end

    it 'does not judge a track whose format could not be read' do
      expect(change('unknown', 'a.mkv', unknown: true)).to be_nil
    end
  end

  describe '.output_audio_count' do
    it 'adds the kept original unless one is already there' do
      tracks = [{ title: 'English' }, { title: 'French' }]
      expect(described_class.output_audio_count(tracks, keep_original: false)).to eq(2)
      expect(described_class.output_audio_count(tracks, keep_original: true)).to eq(3)
      kept = tracks + [{ title: 'English (original, not normalised)' }]
      expect(described_class.output_audio_count(kept, keep_original: true)).to eq(3)
    end
  end

  describe '.measure_loudness audio_index' do
    it 'maps the requested audio stream' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['', '{"input_i":"-18","input_tp":"-2","input_lra":"5","input_thresh":"-28","target_offset":"0"}', ok_status])
      described_class.measure_loudness('a.mkv', audio_index: 2)
      expect(described_class).to have_received(:execute_with_timeout) { |cmd, *_| expect(cmd.each_cons(2)).to include(['-map', '0:a:2']) }
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
                             { index: 0, stream_index: 1, channels: 6, codec: 'ac3', profile: nil, title: nil, language: nil, default: false, bit_rate: 640_000,
                               sample_rate: 48_000 },
                             { index: 1, stream_index: 2, channels: 2, codec: 'aac', profile: nil, title: nil, language: nil, default: false, bit_rate: 256_000,
                               sample_rate: 44_100 }
                           ])
    end

    it 'flags the default-disposition track' do
      json = { streams: [{ index: 1, codec_name: 'aac', disposition: { default: 0 } },
                         { index: 2, codec_name: 'ac3', disposition: { default: 1 } }] }.to_json
      allow(described_class).to receive(:execute_with_timeout).and_return([json, '', ok_status])
      expect(described_class.detect_audio_tracks('a.mkv').map { |t| t[:default] }).to eq([false, true])
    end

    it 'reads the codec profile and track title, treating "unknown" as no profile' do
      ffprobe_json = {
        streams: [
          { index: 1, codec_name: 'truehd', profile: 'Dolby TrueHD + Dolby Atmos', channels: 8,
            tags: { title: 'TrueHD Atmos 7.1' } },
          { index: 2, codec_name: 'eac3', profile: 'unknown', channels: 6 }
        ]
      }.to_json
      allow(described_class).to receive(:execute_with_timeout).and_return([ffprobe_json, '', ok_status])

      result = described_class.detect_audio_tracks('test.mkv')

      expect(result.map { |t| t.slice(:profile, :title) }).to eq([
                                                                   { profile: 'Dolby TrueHD + Dolby Atmos',
                                                                     title: 'TrueHD Atmos 7.1' },
                                                                   { profile: nil, title: nil }
                                                                 ])
    end

    it 'raises FFmpegError when ffprobe fails, instead of fabricating a track' do
      # A failed probe must not silently pass a made-up stereo track
      # downstream to drive real encoder/bitrate selection.
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'err', fail_status])

      expect { described_class.detect_audio_tracks('bad.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /Audio track detection failed/)
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
      expect(result.first[:sample_rate]).to eq(48_000)
    end

    it 'returns an explicitly-marked unknown track when ffprobe emits unparseable json' do
      allow(described_class).to receive(:execute_with_timeout).and_return(['not json', '', ok_status])

      result = described_class.detect_audio_tracks('bad.mkv')
      expect(result).to eq([described_class::UNKNOWN_AUDIO_TRACK])
      expect(result.first[:unknown]).to be(true)
    end

    it 'returns an explicitly-marked unknown track when ffprobe reports no audio streams' do
      allow(described_class).to receive(:execute_with_timeout).and_return([{ streams: [] }.to_json, '', ok_status])

      result = described_class.detect_audio_tracks('no_audio.mkv')
      expect(result).to eq([described_class::UNKNOWN_AUDIO_TRACK])
    end
  end

  describe '.probe_audio_profile_mid_file' do
    let(:track) { { index: 1, codec: 'eac3' } }

    it 'stream-copies a slice from mid-file and returns the profile ffprobe decodes from it' do
      allow(described_class).to receive(:probe_duration).and_return(3600.0)
      allow(described_class).to receive(:execute_with_timeout) do |cmd, _timeout, _name|
        cmd.first == 'ffprobe' ? ["Dolby Digital Plus + Dolby Atmos\n", '', ok_status] : ['', '', ok_status]
      end

      expect(described_class.probe_audio_profile_mid_file('movie.mkv', track))
        .to eq('Dolby Digital Plus + Dolby Atmos')
      expect(described_class).to have_received(:execute_with_timeout).with(
        array_including('-ss', '1800', '-i', 'movie.mkv', '-map', '0:a:1', '-c', 'copy'),
        described_class::QUICK_TIMEOUT, 'Profile slice'
      )
    end

    it 'returns nil for an unnamed profile' do
      allow(described_class).to receive_messages(probe_duration: 60.0,
                                                 execute_with_timeout: ["unknown\n", '', ok_status])

      expect(described_class.probe_audio_profile_mid_file('movie.mkv', track)).to be_nil
    end

    it 'returns nil instead of raising when the slice fails or times out' do
      allow(described_class).to receive(:probe_duration).and_return(60.0)
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'err', fail_status])
      expect(described_class.probe_audio_profile_mid_file('movie.mkv', track)).to be_nil

      allow(described_class).to receive(:execute_with_timeout).and_raise(Neutraliser::FFmpegTimeoutError, 'slow')
      expect(described_class.probe_audio_profile_mid_file('movie.mkv', track)).to be_nil
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

  describe 'constant-gain sample rate pinning' do
    let(:profile) { Neutraliser::Profiles::LIVING_ROOM }

    it 'pins output sample rate to source when no measured peak headroom issue exists' do
      measured = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-25.0', 'input_tp' => '-10.0', 'input_lra' => '0', 'input_thresh' => '0', 'target_offset' => '0')
      plan = Neutraliser::GainPlan.for(measured, profile)
      filter = described_class.send(:build_audio_filter, measured, profile, 48_000, plan: plan)

      expect(filter).to eq('volume=5.00dB,aresample=48000')
      expect(plan.mode).to eq('linear')
    end

    it 'omits aresample when source sample rate is unknown' do
      measured = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-25.0', 'input_tp' => '-10.0', 'input_lra' => '0', 'input_thresh' => '0', 'target_offset' => '0')
      plan = Neutraliser::GainPlan.for(measured, profile)
      filter = described_class.send(:build_audio_filter, measured, profile, nil, plan: plan)

      expect(filter).not_to include('aresample')
    end

    it 'pins aresample on the loudnorm (allow_dynamic) path too, to prevent the 192kHz leak' do
      measured = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-25.0', 'input_tp' => '-10.0', 'input_lra' => '8.0', 'input_thresh' => '-30.0', 'target_offset' => '0.0')
      filter = described_class.send(:build_audio_filter, measured, profile, 48_000, plan: nil)

      expect(filter).to include('loudnorm=')
      expect(filter).to end_with('aresample=48000')
    end
  end

  describe 'integration: metadata + bitrate preservation on a real MKV fixture' do
    def ffprobe_stream(path, select_streams, show_entries)
      json = `ffprobe -v error -select_streams #{select_streams} -show_entries #{show_entries} -of json #{path.shellescape} 2>/dev/null`
      JSON.parse(json)['streams'].first || {}
    end

    before do
      unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
        skip 'ffmpeg/ffprobe not available on PATH'
      end
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
          '-f', 'srt', '-i', '-',
          '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s',
          '-c:v', 'libx264', '-preset', 'ultrafast',
          '-metadata:s:v:0', 'language=eng', '-metadata:s:v:0', 'title=Video Track',
          '-c:a:0', 'aac', '-ac:a:0', '2', '-b:a:0', '256k',
          '-metadata:s:a:0', 'language=eng', '-metadata:s:a:0', 'title=English Track',
          '-c:a:1', 'aac', '-ac:a:1', '2', '-b:a:1', '128k',
          '-metadata:s:a:1', 'language=jpn', '-metadata:s:a:1', 'title=Japanese Track',
          '-c:s', 'srt',
          '-metadata:s:s:0', 'language=fre', '-metadata:s:s:0', 'title=French Subs',
          input
        ]
        srt_fixture = "1\n00:00:00,000 --> 00:00:01,000\nBonjour\n"
        Open3.popen2(*fixture_cmd) do |stdin, _stdout, wait_thr|
          stdin.write(srt_fixture)
          stdin.close
          wait_thr.value
        end
        raise 'fixture generation failed' unless File.exist?(input)

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

        # Regression coverage: video and subtitle streams are plain stream-copies,
        # but issuing any stream-scoped -map_metadata (as the audio tracks above
        # require) disables ffmpeg's implicit per-stream metadata auto-copy for
        # the whole command — video/subtitle need their own explicit mapping too.
        video_tags = ffprobe_stream(output, 'v:0', 'stream_tags=language,title')['tags']
        expect(video_tags['language']).to eq('eng')
        expect(video_tags['title']).to eq('Video Track')

        subtitle_tags = ffprobe_stream(output, 's:0', 'stream_tags=language,title')['tags']
        expect(subtitle_tags['language']).to eq('fre')
        expect(subtitle_tags['title']).to eq('French Subs')

        # Estimated from packet sampling (no BPS tag from ffmpeg's own muxer) —
        # must land near the real ~256k source, not the 128k AAC stereo floor.
        expect(result[:bitrate]).to be > 128_000
        expect(result[:source_bitrate]).to be > 128_000
      end
    end
  end

  describe 'integration: NEUTRALISER_* stamp on real MKV and MP4 output' do
    before do
      unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
        skip 'ffmpeg/ffprobe not available on PATH'
      end
    end

    def make_fixture(path)
      system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
             '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=4',
             '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=4:sample_rate=48000:amplitude=0.05',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k',
             '-metadata:s:a:0', 'language=eng', path, exception: true)
    end

    def language(path)
      `ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=nw=1:nk=1 #{path.shellescape}`.strip
    end

    let(:profile) { Neutraliser::Profiles::LIVING_ROOM }

    %w[mkv mp4].each do |ext|
      it "writes a readable stamp into #{ext} and keeps the stream language tag" do
        Dir.mktmpdir do |dir|
          input = File.join(dir, "in.#{ext}")
          output = File.join(dir, "out.#{ext}")
          make_fixture(input)
          measured = described_class.measure_loudness(input, target_i: profile[:lufs])

          described_class.apply_normalization(input, output, measured, profile)

          stamp = described_class.read_stamp(output)
          expect(stamp).to have_attributes(profile: 'livingroom', mode: 'linear', source_codec: 'aac',
                                           version: Neutraliser::VERSION)
          expect(stamp.gain_db).to be_within(0.01).of(Neutraliser::GainPlan.for(measured, profile).applied.round(2))
          expect(stamp.measured_i).to be_within(0.01).of(measured.input_i)
          expect(language(output)).to eq('eng')
          expect(described_class.read_stamp(input)).to be_nil
        end
      end

      it "re-stamps #{ext} in place without losing stream tags" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "clip.#{ext}")
          make_fixture(path)
          stamp = Neutraliser::Stamp.now(profile: 'night', mode: 'dynamic', gain_db: nil, source_codec: 'aac',
                                         source_bitrate: nil, measured_i: nil, measured_tp: nil, measured_lra: nil)

          described_class.send(:restamp, path, stamp)

          expect(described_class.read_stamp(path)).to have_attributes(profile: 'night', mode: 'dynamic')
          expect(language(path)).to eq('eng')
          expect(Dir.children(dir)).to eq(["clip.#{ext}"])
        end
      end
    end
  end

  # Regression coverage for the class of bug fixed in 36811f5: a filename or
  # path built into a shell string (`.join(' ')` + `system(cmd)`) lets shell
  # metacharacters escape the intended single argument. execute_with_timeout
  # runs `Open3.popen3(*cmd)` (array-form, no shell), so these paths are
  # never tokenized/interpreted - they're each just one argv element handed
  # straight to the ffprobe/ffmpeg process. Real (unmocked) subprocess calls,
  # deliberately, so a future regression to string-built shell commands would
  # actually execute the injected command and fail this test.
  describe 'shell-injection safety (regression for the 36811f5 token-in-shell bug)' do
    it 'never invokes a shell, even when the path contains shell metacharacters' do
      marker = File.join(Dir.mktmpdir, 'pwned')
      malicious_path = "/nonexistent; touch #{marker}; echo '.mp4"

      expect(described_class.probe_duration(malicious_path)).to be_nil
      expect(File.exist?(marker)).to be(false)
    end

    it 'treats a command-substitution-laden path as a literal filename, not a subshell' do
      marker = File.join(Dir.mktmpdir, 'pwned')
      malicious_path = "/nonexistent/$(touch #{marker}).mp4"

      expect(described_class.probe_duration(malicious_path)).to be_nil
      expect(File.exist?(marker)).to be(false)
    end

    it 'handles quotes, spaces, and unicode in filenames as a single literal argument' do
      dir = Dir.mktmpdir
      weird_path = File.join(dir, %(a "quoted" 'file' & spaced 名前.mp4))

      expect(described_class.probe_duration(weird_path)).to be_nil
    ensure
      FileUtils.remove_entry(dir) if dir
    end
  end
end

RSpec.describe 'Neutraliser::FFmpegWrapper timeouts' do
  # Regression: analysis had 300s while normalization had 1800s, despite both
  # decoding the whole audio stream. Files too big to measure in 5 minutes
  # failed before ever reaching the half hour allowed to process them — 339
  # such failures in one real 4,500-episode run over SMB.
  it 'gives analysis at least as long as normalization' do
    expect(Neutraliser::FFmpegWrapper::ANALYSIS_TIMEOUT)
      .to be >= Neutraliser::FFmpegWrapper::NORMALIZATION_TIMEOUT
  end

  describe '.env_timeout' do
    after { ENV.delete('NEUTRALISER_ANALYSIS_TIMEOUT') }

    it 'uses the default when unset' do
      ENV.delete('NEUTRALISER_ANALYSIS_TIMEOUT')
      expect(Neutraliser::FFmpegWrapper.send(:env_timeout, 'ANALYSIS', 1800)).to eq(1800)
    end

    it 'honours an override' do
      ENV['NEUTRALISER_ANALYSIS_TIMEOUT'] = '3600'
      expect(Neutraliser::FFmpegWrapper.send(:env_timeout, 'ANALYSIS', 1800)).to eq(3600)
    end

    it 'falls back to the default for junk or non-positive values' do
      ['0', '-5', 'abc', ''].each do |bad|
        ENV['NEUTRALISER_ANALYSIS_TIMEOUT'] = bad
        expect(Neutraliser::FFmpegWrapper.send(:env_timeout, 'ANALYSIS', 1800)).to eq(1800)
      end
    end
  end

  describe 'container sniffing: MP4 bytes named .mkv' do
    before do
      unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
        skip 'ffmpeg/ffprobe not available on PATH'
      end
    end

    let(:profile) { Neutraliser::Profiles::LIVING_ROOM }

    def make_mp4_named_mkv(dir)
      srt = File.join(dir, 's.srt')
      File.write(srt, "1\n00:00:00,000 --> 00:00:02,000\nhi\n")
      path = File.join(dir, 'fake.mkv')
      system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
             '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=4',
             '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=4:sample_rate=48000:amplitude=0.05',
             '-i', srt, '-map', '0', '-map', '1', '-map', '2',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k', '-c:s', 'mov_text',
             '-f', 'mp4', path, exception: true)
      path
    end

    it 'writes MP4 with the subtitles intact and a readable stamp, instead of failing to mux into Matroska' do
      Dir.mktmpdir do |dir|
        input = make_mp4_named_mkv(dir)
        output = File.join(dir, 'out.mkv')
        measured = Neutraliser::FFmpegWrapper.measure_loudness(input, target_i: profile[:lufs])

        decision = Neutraliser::FFmpegWrapper.apply_normalization(input, output, measured, profile)

        format = `ffprobe -v error -show_entries format=format_name -of csv=p=0 #{output.shellescape}`
        subs = `ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 #{output.shellescape}`
        expect(format).to include('mp4')
        expect(subs.strip).to eq('mov_text')
        expect(decision[:encoder]).to eq('aac')
        expect(Neutraliser::FFmpegWrapper.read_stamp(output)).to have_attributes(profile: 'livingroom', mode: 'linear')
      end
    end
  end
end
