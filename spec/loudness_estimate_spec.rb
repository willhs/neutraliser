# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Neutraliser::LoudnessEstimate do
  describe '.sampled' do
    it 'combines windows on energy, not by averaging LUFS numbers' do
      # Averaging the numbers would give -23.3; the loud window carries the energy.
      estimate = described_class.sampled([-10.0, -30.0, -30.0])

      expect(estimate.level).to be_within(0.01).of(-14.69)
    end

    it 'returns the shared level when every window agrees' do
      expect(described_class.sampled([-22.0, -22.0, -22.0]).level).to be_within(0.001).of(-22.0)
    end

    it 'ignores windows that are missing or not finite' do
      estimate = described_class.sampled([-22.0, nil, -22.0, -Float::INFINITY, -22.0])

      expect(estimate.level).to be_within(0.001).of(-22.0)
      expect(estimate.window_count).to eq(3)
    end

    it 'refuses to report from too few usable windows' do
      expect(described_class.sampled([-22.0, nil, -22.0, nil, nil])).to be_nil
    end
  end

  describe '#verdict' do
    it 'judges a full measurement against the tolerance exactly, like Measurement#needs_normalization?' do
      expect(described_class.exact(-20.9).verdict(-20.0, 1.0)).to eq(:ok)
      expect(described_class.exact(-21.1).verdict(-20.0, 1.0)).to eq(:too_quiet)
      expect(described_class.exact(-18.9).verdict(-20.0, 1.0)).to eq(:too_loud)
    end

    it 'does not call a sample within 0.5 LU of target OK: the true level could be outside the tolerance' do
      estimate = described_class.sampled([-20.4, -20.4, -20.4, -20.4, -20.4])

      expect(estimate.verdict(-20.0, 1.0)).to eq(:unclear)
    end

    it 'does not call a sample 1.5 LU off target needing work: the true level could be inside the tolerance' do
      estimate = described_class.sampled([-21.5, -21.5, -21.5, -21.5, -21.5])

      expect(estimate.verdict(-20.0, 1.0)).to eq(:unclear)
    end

    it 'gives a verdict when the sample is so far off that no sampling error could rescue it' do
      expect(described_class.sampled([-33.0] * 5).verdict(-20.0, 1.0)).to eq(:too_quiet)
      expect(described_class.sampled([-10.0] * 5).verdict(-20.0, 1.0)).to eq(:too_loud)
    end
  end

  describe '#range and #exact?' do
    it 'has no spread for a full measurement' do
      estimate = described_class.exact(-21.0)

      expect(estimate).to be_exact
      expect(estimate.range).to eq(-21.0..-21.0)
    end

    it 'spreads a sample around its level' do
      estimate = described_class.sampled([-21.0] * 5)

      expect(estimate).not_to be_exact
      expect(estimate.range.begin).to be < -21.0
      expect(estimate.range.end).to be > -21.0
    end
  end
end
