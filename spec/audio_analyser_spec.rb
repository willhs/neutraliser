require 'spec_helper'

RSpec.describe Neutraliser::AudioAnalyser do
  let(:target_profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:measured_data) do
    {
      'input_i' => '-18.5',
      'input_tp' => '-2.1',
      'input_lra' => '8.3',
      'input_thresh' => '-28.9',
      'target_offset' => '1.5'
    }
  end

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

  describe '#analyze_file' do
    let(:analyser) { described_class.new(cache_enabled: true, use_sidecar: true) }
    let(:cache_manager) { instance_double(Neutraliser::CacheManager) }

    before do
      allow(Neutraliser::CacheManager).to receive(:new).and_return(cache_manager)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measured_data)
    end

    context 'with cache hit' do
      before do
        allow(cache_manager).to receive(:load_cached_analysis).and_return(measured_data)
        allow(cache_manager).to receive(:save_analysis)
      end

      it 'returns cached data and skips FFmpeg analysis' do
        expect(analyser).to receive(:puts).with("  Using cached analysis data")
        result = analyser.analyze_file('test.mp4', target_profile)

        expect(result).to eq(measured_data)
        expect(Neutraliser::FFmpegWrapper).not_to have_received(:measure_loudness)
      end
    end

    context 'with cache miss' do
      before do
        allow(cache_manager).to receive(:load_cached_analysis).and_return(nil)
        allow(cache_manager).to receive(:save_analysis)
      end

      it 'performs FFmpeg analysis and saves to cache' do
        result = analyser.analyze_file('test.mp4', target_profile)

        expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness).with(
          'test.mp4',
          target_i: target_profile[:lufs],
          target_tp: target_profile[:tp],
          target_lra: target_profile[:lra]
        )
        expect(cache_manager).to have_received(:save_analysis).with('test.mp4', target_profile, measured_data)
        expect(result).to eq(measured_data)
      end
    end

    context 'without sidecar caching' do
      let(:analyser) { described_class.new(cache_enabled: false, use_sidecar: false) }

      it 'performs FFmpeg analysis without caching' do
        result = analyser.analyze_file('test.mp4', target_profile)

        expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness)
        expect(result).to eq(measured_data)
      end
    end

    context 'when FFmpeg analysis fails' do
      before do
        allow(cache_manager).to receive(:load_cached_analysis).and_return(nil)
        allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_raise(Neutraliser::FFmpegError.new("FFmpeg failed"))
      end

      it 'propagates the FFmpeg error' do
        expect {
          analyser.analyze_file('test.mp4', target_profile)
        }.to raise_error(Neutraliser::FFmpegError, "FFmpeg failed")
      end
    end
  end

  describe '#audio_channels' do
    let(:analyser) { described_class.new }

    it 'delegates to FFmpegWrapper' do
      expect(Neutraliser::FFmpegWrapper).to receive(:detect_audio_channels).with('test.mp4').and_return(6)
      result = analyser.audio_channels('test.mp4')
      expect(result).to eq(6)
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

  describe '#cleanup_cache_for_file' do
    let(:analyser) { described_class.new(cache_enabled: true, use_sidecar: true) }
    let(:cache_manager) { instance_double(Neutraliser::CacheManager) }

    before do
      allow(Neutraliser::CacheManager).to receive(:new).and_return(cache_manager)
    end

    it 'delegates to cache manager when sidecar is enabled' do
      expect(cache_manager).to receive(:cleanup_stale_cache).with('test.mp4')
      analyser.cleanup_cache_for_file('test.mp4')
    end

    context 'without sidecar caching' do
      let(:analyser) { described_class.new(cache_enabled: false, use_sidecar: false) }

      it 'does nothing when sidecar is disabled' do
        # Should not raise any errors
        analyser.cleanup_cache_for_file('test.mp4')
      end
    end
  end
end