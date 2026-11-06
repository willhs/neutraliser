RSpec.describe Neutraliser::CodecChoice do
  def make_track(codec:, channels: 2, bit_rate: 256_000, sample_rate: 48_000)
    { index: 0, stream_index: 0, channels: channels, codec: codec, bit_rate: bit_rate, sample_rate: sample_rate }
  end

  it 'matches source AAC codec and bitrate for MP4' do
    result = described_class.decide(make_track(codec: 'aac', bit_rate: 512_000), '.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(320_000) # capped at AAC stereo max
  end

  it 'round-trips AAC-in-MKV as AAC instead of falling back to FLAC' do
    # Regression: with correct field-name parsing, an AAC source in an MKV
    # container must map to the AAC encoder per ADR-0001 priority — not the
    # MKV lossless-fallback (FLAC) that a broken codec parse would trigger.
    result = described_class.decide(make_track(codec: 'aac', bit_rate: 128_000), '.mkv')
    expect(result[:encoder]).to eq('aac')
    expect(result[:lossless_output]).to eq(false)
  end

  it 'matches source AC3 for MKV' do
    result = described_class.decide(make_track(codec: 'ac3', channels: 6, bit_rate: 448_000), '.mkv')
    expect(result[:encoder]).to eq('ac3')
    expect(result[:bitrate]).to eq(448_000)
  end

  it 'enforces quality floor when source bitrate is low' do
    result = described_class.decide(make_track(codec: 'aac', bit_rate: 64_000), '.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'caps bitrate at codec maximum' do
    result = described_class.decide(make_track(codec: 'ac3', channels: 6, bit_rate: 900_000), '.mp4')
    expect(result[:bitrate]).to eq(640_000)
  end

  it 'falls back to FLAC for DTS source in MKV' do
    result = described_class.decide(make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), '.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
    expect(result[:bitrate]).to be_nil
  end

  it 'falls back to EAC3 for DTS source in MP4' do
    result = described_class.decide(make_track(codec: 'dts', channels: 6, bit_rate: 1_509_000), '.mp4')
    expect(result[:encoder]).to eq('eac3')
  end

  it 'falls back to FLAC for TrueHD source in MKV' do
    result = described_class.decide(make_track(codec: 'truehd', channels: 6, bit_rate: 0), '.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
  end

  it 'preserves FLAC for lossless source in MKV' do
    result = described_class.decide(make_track(codec: 'flac', channels: 2, bit_rate: 0), '.mkv')
    expect(result[:encoder]).to eq('flac')
    expect(result[:lossless_output]).to eq(true)
  end

  it 'falls back to high-bitrate AAC for FLAC source in MP4' do
    result = described_class.decide(make_track(codec: 'flac', channels: 2, bit_rate: 0), '.mp4')
    expect(result[:encoder]).to eq('aac')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'uses libopus for Opus source in WebM' do
    result = described_class.decide(make_track(codec: 'opus', bit_rate: 128_000), '.webm')
    expect(result[:encoder]).to eq('libopus')
    expect(result[:bitrate]).to eq(128_000)
  end

  it 'uses libmp3lame for MP3 source in MP4' do
    result = described_class.decide(make_track(codec: 'mp3', bit_rate: 320_000), '.mp4')
    expect(result[:encoder]).to eq('libmp3lame')
    expect(result[:bitrate]).to eq(320_000)
  end

  it 'handles unknown source codec with container fallback' do
    result = described_class.decide(make_track(codec: 'unknown', bit_rate: 0), '.mp4')
    expect(result[:encoder]).to eq('aac')
  end

  it 'uses quality floor when source bitrate is unknown' do
    result = described_class.decide(make_track(codec: 'aac', bit_rate: 0), '.mp4')
    expect(result[:bitrate]).to eq(128_000)
  end

  describe 'a track with no reported bit_rate' do
    let(:track) { make_track(codec: 'aac', bit_rate: nil) }

    it 'uses the floor without sampling when no sampler is given' do
      expect(described_class.decide(track, '.mp4')[:bitrate]).to eq(128_000)
    end

    it 'reads the container BPS tag before sampling' do
      sample = ->(_) { raise 'should not sample' }
      result = described_class.decide(track.merge(tags: { 'BPS' => '192000' }), '.mkv', sample: sample)

      expect(result).to include(encoder: 'aac', bitrate: 192_000, source_bitrate: 192_000)
    end

    it 'samples when there is no tag, and uses a sample above the floor' do
      result = described_class.decide(track, '.mkv', sample: ->(_) { 192_000 })
      expect(result).to include(bitrate: 192_000, source_bitrate: 192_000)
    end

    it 'floors a sample below the minimum' do
      expect(described_class.decide(track, '.mkv', sample: ->(_) { 96_000 })[:bitrate]).to eq(128_000)
    end

    it 'falls to the floor when the sampler finds nothing' do
      result = described_class.decide(track, '.mkv', sample: ->(_) {})
      expect(result).to include(bitrate: 128_000, source_bitrate: 0)
    end

    it 'does not sample a track that reports its bitrate' do
      sample = ->(_) { raise 'should not sample' }
      expect(described_class.decide(make_track(codec: 'aac', bit_rate: 200_000), '.mkv', sample: sample)[:bitrate]).to eq(200_000)
    end
  end

  describe 'changes_codec' do
    def changes?(codec, container)
      described_class.decide(make_track(codec: codec, channels: 6), container)[:changes_codec]
    end

    it 'is false when the codec re-encodes to itself in the container' do
      expect([changes?('aac', '.mkv'), changes?('eac3', '.mp4'), changes?('mp3', '.mkv')]).to all(be(false))
    end

    it 'is true, with the replacement encoder, when the codec cannot be kept' do
      expect(changes?('dts', '.mkv')).to be(true)
      expect(changes?('truehd', '.mkv')).to be(true)
      expect(changes?('flac', '.mp4')).to be(true) # flac has no home in MP4
      expect(described_class.decide(make_track(codec: 'dts', channels: 6), '.mp4')).to include(encoder: 'eac3')
    end

    it 'counts an unreadable channel layout as stereo, the same for the guard and the encode' do
      expect(described_class.decide(make_track(codec: 'dts', channels: 0), '.mkv')).to include(encoder: 'flac', changes_codec: true)
    end
  end
end
