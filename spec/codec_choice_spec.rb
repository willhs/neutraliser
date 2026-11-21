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
    expect(result[:bitrate]).to eq(576_000)
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

  it 'sends Blu-ray big-endian LPCM to FLAC in MKV without counting a codec change' do
    %w[pcm_s24be pcm_s32le pcm_bluray].each do |codec|
      result = described_class.decide(make_track(codec: codec, channels: 8), '.mkv')
      expect(result).to include(encoder: 'flac', lossless_output: true, changes_codec: false)
    end
  end

  it 'still counts lossless-to-lossy as a codec change' do
    expect(described_class.decide(make_track(codec: 'pcm_s24be', channels: 2), '.mp4')).to include(changes_codec: true)
  end

  describe 'more than 5.1 channels (ffmpeg\'s AC-3 and E-AC-3 stop at 5.1)' do
    it 'sends 7.1 E-AC-3 to FLAC where the container allows it' do
      result = described_class.decide(make_track(codec: 'eac3', channels: 8, bit_rate: 1_536_000), '.mkv')
      expect(result).to include(encoder: 'flac', encodable: true, lossless_output: true, changes_codec: true, bitrate: nil)
    end

    it 'sends 6.1 DTS to FLAC in MKV' do
      expect(described_class.decide(make_track(codec: 'dts', channels: 7), '.mkv')).to include(encoder: 'flac')
    end

    it 'has no encoder for 7.1 in an MP4: no FLAC there, and E-AC-3 and AAC are not 7.1 stand-ins' do
      %w[flac eac3 truehd dts].each do |codec|
        result = described_class.decide(make_track(codec: codec, channels: 8), '.mp4')
        expect(result).to include(encoder: nil, encodable: false, bitrate: nil, lossless_output: false)
      end
    end

    it 'keeps 7.1 PCM in a container that takes PCM' do
      result = described_class.decide(make_track(codec: 'pcm_s24le', channels: 8, bit_rate: 0), '.mov')
      expect(result).to include(encoder: 'pcm_s24le', encodable: true)
    end

    it 'leaves stereo and 5.1 as they were' do
      expect(described_class.decide(make_track(codec: 'eac3', channels: 6, bit_rate: 640_000), '.mp4'))
        .to include(encoder: 'eac3', encodable: true, bitrate: 800_000)
      expect(described_class.decide(make_track(codec: 'flac', channels: 6, bit_rate: 0), '.mp4')).to include(encoder: 'eac3', encodable: true)
      expect(described_class.decide(make_track(codec: 'dts', channels: 6), '.mp4')).to include(encoder: 'eac3', encodable: true)
    end
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

      expect(result).to include(encoder: 'aac', bitrate: 240_000, source_bitrate: 192_000)
    end

    it 'samples when there is no tag, and uses a sample above the floor' do
      result = described_class.decide(track, '.mkv', sample: ->(_) { 192_000 })
      expect(result).to include(bitrate: 240_000, source_bitrate: 192_000)
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
      expect(described_class.decide(make_track(codec: 'aac', bit_rate: 200_000), '.mkv', sample: sample)[:bitrate]).to eq(250_000)
    end
  end

  describe 'bitrate headroom (research 0004)' do
    def rate(codec, bit_rate, channels: 2, container: '.mkv', stamp: nil)
      described_class.decide(make_track(codec: codec, channels: channels, bit_rate: bit_rate), container, stamp: stamp)[:bitrate]
    end

    it 'adds 25% to the measured rates: stereo AAC, 5.1 AAC, AC-3 and E-AC-3' do
      expect(rate('aac', 128_000)).to eq(160_000)
      expect(rate('aac', 384_000, channels: 6)).to eq(480_000)
      expect(rate('ac3', 448_000, channels: 6)).to eq(576_000)
      expect(rate('eac3', 640_000, channels: 6)).to eq(800_000)
    end

    it 'lands on a rate the AC-3 encoder takes, rounding up to the next step' do
      expect(rate('ac3', 384_000, channels: 6)).to eq(512_000) # 480k is not a step
      expect(rate('ac3', 192_000)).to eq(256_000) # 240k is not a step
      expect(rate('ac3', 640_000, channels: 6)).to eq(640_000) # the cap, also a step
      expect(described_class::AC3_BITRATES).to include(448_000, 512_000, 576_000, 640_000)
    end

    it 'stays inside the floors and caps' do
      expect(rate('aac', 320_000)).to eq(320_000)
      expect(rate('aac', 64_000)).to eq(128_000)
      expect(rate('aac', 0)).to eq(128_000) # unknown stays at the floor, nothing to add to
    end

    it 'gives 7.1 its own cap, so a 641k 7.1 AAC is not pulled down to the 5.1 cap of 512k' do
      expect(rate('aac', 641_000, channels: 8, container: '.mp4')).to eq(768_000) # 801k, held by the 7.1 cap
      expect(rate('aac', 641_000, channels: 6, container: '.mp4')).to eq(512_000) # 5.1 cap unchanged
      expect(rate('aac', 384_000, channels: 8, container: '.mp4')).to eq(480_000) # under the cap: +25%
      expect(rate('aac', 0, channels: 8, container: '.mp4')).to eq(320_000) # 7.1 floor
    end

    it 'gives 7.1 Opus and Vorbis their own floors and caps' do
      expect(rate('opus', 800_000, channels: 8, container: '.webm')).to eq(680_000) # no headroom: held by the cap
      expect(rate('vorbis', 800_000, channels: 8, container: '.webm')).to eq(700_000)
      expect(rate('opus', 128_000, channels: 8, container: '.webm')).to eq(320_000)
    end

    it 'leaves encoders it was not measured on alone' do
      expect(rate('mp3', 192_000)).to eq(192_000)
      expect(rate('opus', 128_000, container: '.webm')).to eq(128_000)
    end

    it 'does not apply to a codec change, which keeps the old rule' do
      expect(rate('dts', 1_509_000, channels: 6, container: '.mp4')).to eq(1_509_000)
    end

    describe 'with an earlier stamp' do
      def stamp(codec:, bitrate:)
        Neutraliser::Stamp.now(profile: 'livingroom', mode: 'linear', gain_db: 1.0, source_codec: codec, source_bitrate: bitrate,
                               measured_i: -24.0, measured_tp: -3.0, measured_lra: 8.0)
      end

      it 'works from the first-generation bitrate, so a redo of a 160k output lands on 160k again' do
        result = described_class.decide(make_track(codec: 'aac', bit_rate: 160_000), '.mkv', stamp: stamp(codec: 'aac', bitrate: 128_000))

        expect(result).to include(bitrate: 160_000, source_bitrate: 160_000, first_generation_bitrate: 128_000)
      end

      it 'treats a stamp from before headroom the same: its output sits at the first-generation rate' do
        result = described_class.decide(make_track(codec: 'ac3', channels: 6, bit_rate: 448_000), '.mkv', stamp: stamp(codec: 'ac3', bitrate: 448_000))

        expect(result).to include(bitrate: 576_000, first_generation_bitrate: 448_000)
      end

      it 'ignores a stamp for another codec or with no bitrate' do
        track = make_track(codec: 'eac3', channels: 6, bit_rate: 640_000)

        expect(described_class.decide(track, '.mkv', stamp: stamp(codec: 'dts', bitrate: 1_509_000))[:first_generation_bitrate]).to eq(640_000)
        expect(described_class.decide(track, '.mkv', stamp: stamp(codec: 'eac3', bitrate: nil))[:first_generation_bitrate]).to eq(640_000)
      end
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
