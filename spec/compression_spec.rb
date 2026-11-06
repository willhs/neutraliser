require 'spec_helper'

RSpec.describe Neutraliser::Compression do
  let(:profile) { Neutraliser::Profiles::LIVING_ROOM } # -20 LUFS, -1.5 dBTP

  def measurement(input_i: -22.0, input_tp: -8.0, input_lra: 17.0)
    Neutraliser::Measurement.new(input_i: input_i, input_tp: input_tp, input_lra: input_lra,
                                 input_thresh: -32.0, target_offset: 0.0)
  end

  describe 'LADDER' do
    it 'gets stronger at every step: lower threshold, higher ratio' do
      pairs = described_class::LADDER.each_cons(2).to_a

      expect(pairs).to all(satisfy { |a, b| b.threshold_offset_db < a.threshold_offset_db && b.ratio > a.ratio })
    end

    it 'starts and ends at the settings the first A/B clips used' do
      gentle = described_class::LADDER.first
      strong = described_class::LADDER.find { |rung| rung.name == 'strong' }

      expect(gentle).to have_attributes(ratio: 2.5, attack_ms: 20, release_ms: 300, threshold_offset_db: -6)
      expect(strong).to have_attributes(ratio: 4.0, attack_ms: 10, release_ms: 250, threshold_offset_db: -12)
    end
  end

  describe Neutraliser::Compression::Rung do
    it 'puts the threshold a fixed offset under the file level, as a linear amplitude' do
      filter = described_class.new(name: 'x', threshold_offset_db: -6, ratio: 2.5, attack_ms: 20, release_ms: 300).filter(-22.0)

      expect(filter).to eq('acompressor=threshold=0.03981:ratio=2.5:attack=20:release=300:knee=4:detection=rms:link=maximum')
    end

    it 'keeps the threshold inside what acompressor accepts for a very quiet file' do
      rung = described_class.new(name: 'x', threshold_offset_db: -24, ratio: 8.0, attack_ms: 10, release_ms: 250)

      expect(rung.filter(-60.0)).to include('threshold=0.00098')
    end
  end

  describe '.needed?' do
    it 'is true only when the LRA is over the target by more than the tolerance' do
      expect(described_class.needed?(measurement(input_lra: 13.1), lra_target: 12.0, tolerance: 1.0)).to be true
      expect(described_class.needed?(measurement(input_lra: 13.0), lra_target: 12.0, tolerance: 1.0)).to be false
      expect(described_class.needed?(measurement(input_lra: 8.0), lra_target: 12.0, tolerance: 1.0)).to be false
    end

    it 'is false for silent files and the already-at-target sentinel' do
      silent = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-inf', 'input_tp' => '-inf', 'input_lra' => '30',
                                                           'input_thresh' => '-70', 'target_offset' => '0')

      expect(described_class.needed?(silent, lra_target: 12.0, tolerance: 1.0)).to be false
      expect(described_class.needed?(Neutraliser::Measurement.already_at_target(profile), lra_target: 3.0, tolerance: 0.0)).to be false
    end
  end

  describe '.centre_boost_filter' do
    it 'lifts only channel 3 and keeps the layout the track has' do
      filter = described_class.centre_boost_filter({ channel_layout: '5.1(side)' }, 4.0)

      expect(filter).to eq('pan=5.1(side)|c0=c0|c1=c1|c2=1.5849*c2|c3=c3|c4=c4|c5=c5')
    end

    it 'does nothing without a boost, or for a track with no known centre channel' do
      expect(described_class.centre_boost_filter({ channel_layout: '5.1' }, 0.0)).to be_nil
      expect(described_class.centre_boost_filter({ channel_layout: 'stereo' }, 4.0)).to be_nil
      expect(described_class.centre_boost_filter({ channel_layout: nil }, 4.0)).to be_nil
    end
  end

  describe '.plan' do
    let(:track) { { index: 1, channels: 6, channel_layout: '5.1' } }
    # LRA measured after each rung, gentlest first.
    let(:lra_by_rung) { [15.0, 13.0, 11.0, 9.0, 8.0, 7.0] }

    def stub_measurements(lras)
      calls = []
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_path, pre_filter:, **|
        rung = described_class::LADDER.index { |candidate| pre_filter.include?("ratio=#{candidate.ratio}:") }
        calls << rung
        measurement(input_i: -30.0, input_tp: -18.0, input_lra: lras.fetch(rung))
      end
      calls
    end

    def plan(lra_target:, **options)
      described_class.plan('film.mkv', track, measurement, profile, lra_target: lra_target, tolerance: 1.0, **options)
    end

    it 'picks the gentlest rung whose LRA is within target + tolerance' do
      stub_measurements(lra_by_rung)

      expect(plan(lra_target: 10.0)).to have_attributes(rung: have_attributes(name: 'strong'), reached?: true)
      expect(plan(lra_target: 14.0)).to have_attributes(rung: have_attributes(name: 'gentle'), reached?: true)
    end

    it 'measures at most log2(rungs) + 1 candidates, not all of them' do
      calls = stub_measurements(lra_by_rung)

      plan(lra_target: 7.0)

      expect(calls.uniq.length).to be <= 4
    end

    it 'falls back to the strongest rung and says the target was not reached' do
      stub_measurements(lra_by_rung)

      expect(plan(lra_target: 3.0)).to have_attributes(rung: have_attributes(name: 'extreme'), reached?: false)
    end

    it 'levels the compressed signal, not the original, to the profile target' do
      stub_measurements(lra_by_rung)

      result = plan(lra_target: 14.0)

      expect(result.applied).to eq(10.0) # -30 LUFS after compression to the -20 target
      expect(result.filter).to start_with('acompressor=').and include(',volume=10.00dB')
      expect(result).to have_attributes(mode: Neutraliser::Mode::COMPRESSED, limited: false, label: 'gentle')
    end

    it 'adds the limiter when --limit-db lets the gain run past the peak ceiling' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)
        .and_return(measurement(input_i: -30.0, input_tp: -6.0, input_lra: 9.0))

      result = plan(lra_target: 10.0, limit_db: 6.0)

      expect(result).to have_attributes(limited: true, label: 'gentle+limiter')
      expect(result.filter).to include('alimiter=')
    end

    it 'puts the centre boost ahead of the compressor, in measurement and in the final chain' do
      seen = []
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness) do |_path, pre_filter:, **|
        seen << pre_filter
        measurement(input_i: -30.0, input_tp: -18.0, input_lra: 9.0)
      end

      result = plan(lra_target: 10.0, centre_boost_db: 4.0)

      expect(seen).to all(start_with('pan=5.1|c0=c0|c1=c1|c2=1.5849*c2').and(include(',acompressor=')))
      expect(result.chain).to eq(seen.last)
      expect(result.centre_boost_db).to eq(4.0)
    end

    it 'records no boost when the track has no 5.1 centre channel' do
      stub_measurements(lra_by_rung)

      result = described_class.plan('film.mkv', { index: 0, channel_layout: 'stereo' }, measurement, profile,
                                    lra_target: 14.0, tolerance: 1.0, centre_boost_db: 4.0)

      expect(result.centre_boost_db).to eq(0.0)
      expect(result.chain).not_to include('pan=')
    end

    it 'measures the track the pre-chain will run on' do
      stub_measurements(lra_by_rung)

      plan(lra_target: 14.0)

      expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness).with('film.mkv', hash_including(audio_index: 1)).at_least(:once)
    end
  end
end
