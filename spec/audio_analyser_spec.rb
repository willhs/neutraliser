require 'spec_helper'

RSpec.describe Neutraliser::AudioAnalyser do
  let(:target_profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }

  describe '#initialize' do
    context 'with default parameters' do
      it 'enables cache and sidecar by default' do
        analyser = described_class.new
        expect(analyser.instance_variable_get(:@cache_enabled)).to be true
        expect(analyser.instance_variable_get(:@use_sidecar)).to be true
      end
    end

    context 'with cache disabled' do
      it 'creates analyser without cache manager' do
        analyser = described_class.new(cache_enabled: false, use_sidecar: false)
        expect(analyser.instance_variable_get(:@cache_manager)).to be_nil
      end
    end

    context 'with sidecar enabled' do
      it 'initializes cache manager' do
        expect(Neutraliser::CacheManager).to receive(:new).with(enabled: true)
        described_class.new(cache_enabled: true, use_sidecar: true)
      end
    end
  end

  describe '#needs_normalization?' do
    let(:analyser) { described_class.new }

    context 'when current LUFS is within tolerance' do
      let(:measured_data) { { 'input_i' => '-19.5' } }  # 0.5 LU from -20.0 target

      it 'returns false with default tolerance (1.0)' do
        result = analyser.needs_normalization?(measured_data, target_profile)
        expect(result).to be false
      end

      it 'returns true with tighter tolerance' do
        result = analyser.needs_normalization?(measured_data, target_profile, tolerance: 0.3)
        expect(result).to be true
      end
    end

    context 'when current LUFS is outside tolerance' do
      let(:measured_data) { { 'input_i' => '-16.0' } }  # 4.0 LU from -20.0 target

      it 'returns true' do
        result = analyser.needs_normalization?(measured_data, target_profile)
        expect(result).to be true
      end
    end

    context 'with different profile targets' do
      let(:night_profile) { { lufs: -16.0 } }
      let(:measured_data) { { 'input_i' => '-16.8' } }  # 0.8 LU from -16.0 target

      it 'calculates correctly for different target levels' do
        result = analyser.needs_normalization?(measured_data, night_profile)
        expect(result).to be false  # Within default 1.0 tolerance
      end
    end
  end
end