require 'spec_helper'

RSpec.describe Neutraliser::PlexAnalyzer do
  let(:server_url) { 'http://plex.local:32400' }
  let(:token) { 'super-secret-token' }
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }

  subject(:analyzer) do
    described_class.new(server_url: server_url, token: token, profile: profile, tolerance: 1.0)
  end

  before do
    allow(Neutraliser.logger).to receive(:log)
    analyzer.instance_variable_set(:@auth_token, token)
  end

  def measurement_for(lufs)
    Neutraliser::Measurement.from_loudnorm_json(
      'input_i' => lufs.to_s, 'input_tp' => '-1.0', 'input_lra' => '5.0',
      'input_thresh' => '-30.0', 'target_offset' => '0.0'
    )
  end

  def media_item(title, part_key, duration_s: nil)
    item = { 'title' => title, 'Media' => [{ 'Part' => [{ 'key' => part_key }] }] }
    item['duration'] = (duration_s * 1000).to_i if duration_s
    item
  end

  def silent_measurement
    Neutraliser::Measurement.from_loudnorm_json(
      'input_i' => '-inf', 'input_tp' => '-inf', 'input_lra' => '0.00',
      'input_thresh' => '-70.00', 'target_offset' => 'inf'
    )
  end

  describe '#get_plex_streaming_url (private)' do
    it 'never embeds the token in the URL' do
      url = analyzer.send(:get_plex_streaming_url, media_item('Movie', '/library/parts/1/file.mkv'))

      expect(url).to eq("#{server_url}/library/parts/1/file.mkv")
      expect(url).not_to include(token)
    end
  end

  describe '#analyze_streaming_audio (private)' do
    it 'measures via FFmpegWrapper with the token passed as an ffmpeg -headers arg, never in argv' do
      measurement = measurement_for(-18.0)

      expect(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |url, **kwargs|
        expect(url).to eq("#{server_url}/library/parts/1/file.mkv")
        expect(url).not_to include(token)
        expect(kwargs[:input_args]).to eq(['-headers', "X-Plex-Token: #{token}\r\n"])
        measurement
      end

      result = analyzer.send(:analyze_streaming_audio, "#{server_url}/library/parts/1/file.mkv")

      expect(result).to eq(measurement)
    end

    it 'propagates ffmpeg failures instead of returning a sentinel float' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)
        .and_raise(Neutraliser::FFmpegError, 'boom')

      expect { analyzer.send(:analyze_streaming_audio, "#{server_url}/x") }
        .to raise_error(Neutraliser::FFmpegError)
    end
  end

  describe '#analyze_media_item (private)' do
    it 'does not discard a genuine -18.0 LUFS measurement as a sentinel failure' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement_for(-18.0))

      result = analyzer.send(:analyze_media_item, media_item('Loud Movie', '/library/parts/1/file.mkv'), 'movie')

      expect(result).not_to be_nil
      expect(result[:current_level]).to eq(-18.0)
    end

    it 'skips the item (returns nil) when measurement fails, without inventing a level' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)
        .and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      result = analyzer.send(:analyze_media_item, media_item('Slow Movie', '/library/parts/1/file.mkv'), 'movie')

      expect(result).to be_nil
    end

    it 'delegates the needs-adjustment decision to Measurement#needs_normalization? using the configured profile/tolerance' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement_for(-20.4))

      result = analyzer.send(:analyze_media_item, media_item('Close Movie', '/library/parts/1/file.mkv'), 'movie')

      expect(result[:needs_adjustment]).to eq(measurement_for(-20.4).needs_normalization?(profile, tolerance: 1.0))
      expect(result[:needs_adjustment]).to be false
      expect(result[:target_level]).to eq(profile[:lufs])
    end
  end

  describe '#analyze_media_item judging a long title (private)' do
    let(:film) { media_item('Long Film', '/library/parts/1/file.mkv', duration_s: 6000) }

    def analyze(item = film, analyzer: self.analyzer)
      analyzer.send(:analyze_media_item, item, 'movie')
    end

    it 'measures five 60s windows spread across the runtime, not one slice' do
      calls = []
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_url, **kwargs|
        calls << kwargs.slice(:start_offset, :duration)
        measurement_for(-20.0)
      end

      analyze

      expect(calls).to eq([570, 1770, 2970, 4170, 5370].map { |at| { start_offset: at.to_f, duration: 60 } })
    end

    it 'does not label a film Too Quiet from a sample that reads ~3 LU low (Chariots of Fire: sample -23.2, true -20.0)' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement_for(-23.2))

      result = analyze

      expect(result[:measured]).to eq('sampled')
      expect(result[:needs_adjustment]).to be false
      expect(result[:adjustment_type]).to eq('Unclear')
    end

    it 'still flags a film that is far from target however the sample falls' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement_for(-31.0))

      result = analyze

      expect(result[:needs_adjustment]).to be true
      expect(result[:adjustment_type]).to eq('Too Quiet')
    end

    it 'reports the range the true level could be in alongside the estimate' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement_for(-23.0))

      low, high = analyze[:level_range]

      expect(low).to be < -23.0
      expect(high).to be > -23.0
    end

    it 'combines the windows on energy: one loud window outweighs quiet ones' do
      levels = [-30.0, -30.0, -10.0, -30.0, -30.0]
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) { measurement_for(levels.shift) }

      expect(analyze[:current_level]).to be_within(0.01).of(-16.82)
    end

    it 'drops a window that fails or is silent and still reports from the rest' do
      responses = [-22.0, :boom, silent_measurement, -22.0, -22.0]
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do
        response = responses.shift
        raise Neutraliser::FFmpegError, 'Server returned 5XX' if response == :boom

        response.is_a?(Neutraliser::Measurement) ? response : measurement_for(response)
      end

      result = analyze

      expect(result[:current_level]).to be_within(0.001).of(-22.0)
    end

    it 'skips the title rather than report from fewer than three readable windows' do
      responses = [-22.0, :boom, silent_measurement, :boom, -22.0]
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do
        response = responses.shift
        raise Neutraliser::FFmpegError, 'Server returned 5XX' if response == :boom

        response.is_a?(Neutraliser::Measurement) ? response : measurement_for(response)
      end

      expect(analyze).to be_nil
    end

    it 'does not turn a silent read into a 0.0 LUFS "Too Loud" result' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(silent_measurement)

      expect(analyze).to be_nil
      expect(analyze(media_item('Short', '/library/parts/2/file.mkv', duration_s: 120))).to be_nil
    end
  end

  describe '#analyze_media_item reading a title in full (private)' do
    it 'reads a short title end to end and judges it exactly' do
      calls = []
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_url, **kwargs|
        calls << kwargs.slice(:start_offset, :duration)
        measurement_for(-21.4)
      end

      result = analyzer.send(:analyze_media_item, media_item('Episode', '/library/parts/3/file.mkv', duration_s: 200), 'show')

      expect(calls).to eq([{ start_offset: nil, duration: nil }])
      expect(result[:measured]).to eq('full')
      expect(result[:adjustment_type]).to eq('Too Quiet')
    end

    it 'with full: true reads a long title end to end in one pass and gives a firm verdict near the tolerance edge' do
      full_analyzer = described_class.new(server_url: server_url, token: token, profile: profile, tolerance: 1.0, full: true)
      full_analyzer.instance_variable_set(:@auth_token, token)
      calls = []
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_url, **kwargs|
        calls << kwargs.slice(:start_offset, :duration)
        measurement_for(-20.6)
      end

      result = full_analyzer.send(:analyze_media_item, media_item('Long', '/library/parts/4/file.mkv', duration_s: 7000), 'movie')

      expect(calls).to eq([{ start_offset: nil, duration: nil }])
      expect(result[:measured]).to eq('full')
      expect(result[:adjustment_type]).to eq('OK')
    end
  end

  describe 'reporting sampled and full results (private)' do
    def result(title, level, measured:, verdict:)
      exact = measured == 'full'
      low, high = exact ? [level, level] : [level - 1.0, level + 7.0]
      {
        title: title, file_path: "#{server_url}/#{title}", library_type: 'movie', content_type: :movie,
        current_level: level, target_level: -20.0, level_difference: level + 20.0, level_range: [low, high],
        measured: measured, verdict: verdict, needs_adjustment: %i[too_loud too_quiet].include?(verdict),
        adjustment_type: described_class::ADJUSTMENT_LABELS.fetch(verdict)
      }
    end

    let(:results) do
      [
        result('Whisper Film', -33.0, measured: 'sampled', verdict: :too_quiet),
        result('Probably Fine Film', -22.5, measured: 'sampled', verdict: :unclear),
        result('Short Episode', -20.2, measured: 'full', verdict: :ok)
      ]
    end

    it 'separates titles it can judge from titles a sample cannot settle, and says so' do
      output = []
      allow(Neutraliser.logger).to receive(:log) { |message| output << message }

      analyzer.send(:generate_table_report, results)
      text = output.join("\n")

      expect(text).to include('Files needing adjustment: 1')
      expect(text).to include("Can't tell from a sample: 1")
      expect(text).to include('Files within target range: 1')
      expect(text).to match(/Estimated levels: lowest -33\.0, median -22\.5, highest -20\.2 LUFS/)
      expect(text).to include('--full')

      adjust_section, unclear_section = text.split("CAN'T TELL FROM A SAMPLE")
      expect(adjust_section).to include('Whisper Film')
      expect(adjust_section).not_to include('Probably Fine Film')
      expect(unclear_section).to include('Probably Fine Film')
    end

    it 'keeps the unclear table to the worst few and points at csv/json for the rest' do
      many = Array.new(40) { |i| result("Film #{i}", -22.0 - i * 0.1, measured: 'sampled', verdict: :unclear) }
      output = []
      allow(Neutraliser.logger).to receive(:log) { |message| output << message }

      analyzer.send(:generate_table_report, many)

      expect(output.join("\n")).to include('…and 15 more')
    end

    it 'writes verdict, how each title was measured and its range to the JSON report' do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { analyzer.send(:generate_json_report, results) }
        report = JSON.parse(File.read(Dir.glob(File.join(dir, 'plex_audio_analysis_*.json')).first))

        expect(report['files_needing_adjustment']).to eq(1)
        expect(report['files_unclear']).to eq(1)
        expect(report['results'].map { |r| r['measured'] }).to eq(%w[sampled sampled full])
        expect(report['results'][1]['verdict']).to eq('unclear')
        expect(report['results'][1]['level_range']).to eq([-23.5, -15.5])
      end
    end
  end

  describe '#connect_to_plex (private)' do
    it 'raises PlexAnalyzerError instead of exiting when no token is configured' do
      no_token_analyzer = described_class.new(server_url: server_url, token: nil, profile: profile)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PLEX_TOKEN', nil).and_return(nil)

      expect { no_token_analyzer.send(:connect_to_plex) }
        .to raise_error(Neutraliser::PlexAnalyzerError, /No Plex token found/)
    end

    it 'raises PlexAnalyzerError instead of exiting on a failed connection test' do
      response = instance_double(Net::HTTPResponse, code: '500', message: 'Internal Server Error')
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:request).and_return(response)

      expect { analyzer.send(:connect_to_plex) }
        .to raise_error(Neutraliser::PlexAnalyzerError, /Connection failed/)
    end
  end

  it 'has no library-owned target table or variance constant — Profiles is the single target authority' do
    expect(described_class.constants).not_to include(:TARGET_LEVELS)
    expect(described_class.constants).not_to include(:ACCEPTABLE_VARIANCE)
  end
end
