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

  def media_item(title, part_key)
    { 'title' => title, 'Media' => [{ 'Part' => [{ 'key' => part_key }] }] }
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

  describe '#connect_to_plex (private)' do
    it 'raises PlexAnalyzerError instead of exiting when no token is configured' do
      no_token_analyzer = described_class.new(server_url: server_url, token: nil, profile: profile)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('PLEX_TOKEN').and_return(nil)

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
