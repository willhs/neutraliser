require 'spec_helper'

RSpec.describe Neutraliser::Measurement do
  let(:target_profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }

  describe '.from_loudnorm_json' do
    it 'coerces ffmpeg loudnorm JSON string values into typed floats' do
      measurement = described_class.from_loudnorm_json(
        'input_i' => '-18.5', 'input_tp' => '-2.1', 'input_lra' => '8.3',
        'input_thresh' => '-28.9', 'target_offset' => '1.5'
      )

      expect(measurement.input_i).to eq(-18.5)
      expect(measurement.input_tp).to eq(-2.1)
      expect(measurement.input_lra).to eq(8.3)
      expect(measurement.input_thresh).to eq(-28.9)
      expect(measurement.target_offset).to eq(1.5)
      expect(measurement.already_at_target?).to be false
      expect(measurement.silent?).to be false
    end

    it 'flags a "-inf" input_i (nothing to measure) as silent rather than a 0.0 LUFS reading' do
      measurement = described_class.from_loudnorm_json(
        'input_i' => '-inf', 'input_tp' => '-inf', 'input_lra' => '0.00',
        'input_thresh' => '-70.00', 'target_offset' => 'inf'
      )

      expect(measurement.silent?).to be true
    end
  end

  describe '.from_cache_h' do
    it 'rebuilds a Measurement from a sidecar cache hash' do
      measurement = described_class.from_cache_h(
        'input_i' => '-18.5', 'input_tp' => '-2.1', 'input_lra' => '8.3',
        'input_thresh' => '-28.9', 'target_offset' => '1.5',
        'cache_version' => '1.1', 'cached_at' => '2026-01-01T00:00:00Z'
      )

      expect(measurement.input_i).to eq(-18.5)
    end

    it 'returns nil when required loudnorm fields are missing' do
      expect(described_class.from_cache_h('input_i' => '-18.5')).to be_nil
    end

    it 'returns nil for a non-hash input' do
      expect(described_class.from_cache_h(nil)).to be_nil
    end
  end

  describe '.already_at_target' do
    it 'builds a Measurement that never fabricates an input_thresh' do
      measurement = described_class.already_at_target(target_profile)

      expect(measurement.already_at_target?).to be true
      expect(measurement.input_i).to eq(target_profile[:lufs])
      expect(measurement.input_thresh).to be_nil
      expect(measurement.target_offset).to eq(0.0)
    end

    it 'always reports no normalization needed, regardless of tolerance' do
      measurement = described_class.already_at_target(target_profile)

      expect(measurement.needs_normalization?(target_profile, tolerance: 0.0)).to be false
    end
  end

  describe '#needs_normalization?' do
    it 'returns false when within tolerance' do
      measurement = described_class.from_loudnorm_json('input_i' => '-19.5', 'input_tp' => '0', 'input_lra' => '0', 'input_thresh' => '0', 'target_offset' => '0')

      expect(measurement.needs_normalization?(target_profile)).to be false
      expect(measurement.needs_normalization?(target_profile, tolerance: 0.3)).to be true
    end

    it 'returns true when outside tolerance' do
      measurement = described_class.from_loudnorm_json('input_i' => '-16.0', 'input_tp' => '0', 'input_lra' => '0', 'input_thresh' => '0', 'target_offset' => '0')

      expect(measurement.needs_normalization?(target_profile)).to be true
    end
  end

  describe '#with_all_channels' do
    let(:loudnorm) do
      described_class.from_loudnorm_json('input_i' => '-27.07', 'input_tp' => '-21.9', 'input_lra' => '3.0',
                                         'input_thresh' => '-37.1', 'target_offset' => '0.01')
    end

    it 'takes the integrated loudness, gate and offset from ebur128 and keeps loudnorm\'s range' do
      measurement = loudnorm.with_all_channels(integrated: -25.3, threshold: -35.3, true_peak: -21.9, target_i: -20.0)

      expect(measurement).to have_attributes(input_i: -25.3, input_thresh: -35.3, input_lra: 3.0)
      expect(measurement.target_offset).to be_within(0.001).of(5.3)
    end

    it 'keeps the higher of the two peaks' do
      expect(loudnorm.with_all_channels(integrated: -25.3, threshold: nil, true_peak: -18.0, target_i: -20.0).input_tp).to eq(-18.0)
      expect(loudnorm.with_all_channels(integrated: -25.3, threshold: nil, true_peak: -30.0, target_i: -20.0).input_tp).to eq(-21.9)
    end

    it 'leaves a silent measurement silent' do
      silent = described_class.from_loudnorm_json('input_i' => '-inf', 'input_tp' => '-inf', 'input_lra' => '0',
                                                  'input_thresh' => '-70', 'target_offset' => '0')

      expect(silent.with_all_channels(integrated: -Float::INFINITY, threshold: -70.0, true_peak: -Float::INFINITY, target_i: -20.0)).to be_silent
    end

    it 'keeps loudnorm\'s figure when ebur128 gave no loudness' do
      expect(loudnorm.with_all_channels(integrated: nil, threshold: nil, true_peak: nil, target_i: -20.0)).to eq(loudnorm)
    end
  end

  describe '#to_cache_h' do
    it 'round-trips through .from_cache_h' do
      original = described_class.from_loudnorm_json(
        'input_i' => '-18.5', 'input_tp' => '-2.1', 'input_lra' => '8.3',
        'input_thresh' => '-28.9', 'target_offset' => '1.5'
      )

      rebuilt = described_class.from_cache_h(original.to_cache_h)

      expect(rebuilt).to eq(original)
    end
  end
end
