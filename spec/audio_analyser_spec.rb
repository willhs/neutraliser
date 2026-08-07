require 'spec_helper'

RSpec.describe Neutraliser::AudioAnalyser do
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:measurement) do
    Neutraliser::Measurement.from_loudnorm_json(
      'input_i' => '-18.5', 'input_tp' => '-2.1', 'input_lra' => '8.3',
      'input_thresh' => '-28.9', 'target_offset' => '1.5'
    )
  end

  describe '#analyze' do
    context 'when fast verification says no analysis is needed' do
      it 'returns an already-at-target Measurement without measuring or hitting the cache' do
        analyser = described_class.new(cache_enabled: true, fast_verification: true)
        allow_any_instance_of(Neutraliser::FastVerifier).to receive(:needs_analysis?).and_return(false)
        expect(Neutraliser::FFmpegWrapper).not_to receive(:measure_loudness)

        result = analyser.analyze('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile)

        expect(result.already_at_target?).to be true
        expect(result.needs_normalization?(profile)).to be false
      end
    end

    context 'when a cached measurement exists' do
      it 'returns the cached Measurement without re-measuring' do
        analyser = described_class.new(cache_enabled: true, fast_verification: false)
        allow_any_instance_of(Neutraliser::CacheManager).to receive(:load_cached_analysis).and_return(measurement)
        expect(Neutraliser::FFmpegWrapper).not_to receive(:measure_loudness)

        result = analyser.analyze('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile)

        expect(result).to eq(measurement)
      end
    end

    context 'on a cache miss' do
      it 'measures the working path, caches it under cached_as, and returns the Measurement' do
        analyser = described_class.new(cache_enabled: true, fast_verification: false)
        allow_any_instance_of(Neutraliser::CacheManager).to receive(:load_cached_analysis).and_return(nil)
        allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness)
          .with('/working/movie.mp4', target_i: profile[:lufs], target_tp: profile[:tp], target_lra: profile[:lra])
          .and_return(measurement)

        expect_any_instance_of(Neutraliser::CacheManager).to receive(:save_analysis)
          .with('/orig/movie.mp4', profile, measurement)

        result = analyser.analyze('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile)

        expect(result).to eq(measurement)
      end
    end

    context 'with cache disabled' do
      it 'constructs a disabled CacheManager and never reads or writes the sidecar' do
        analyser = described_class.new(cache_enabled: false, fast_verification: false)
        allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_return(measurement)

        expect(File).not_to receive(:write)

        result = analyser.analyze('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile)

        expect(result).to eq(measurement)
      end
    end

    it 'raises ffmpeg errors instead of falling back to fake data' do
      analyser = described_class.new(cache_enabled: false, fast_verification: false)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_raise(Neutraliser::FFmpegError, 'boom')

      expect { analyser.analyze('/working/movie.mp4', cached_as: '/orig/movie.mp4', profile: profile) }
        .to raise_error(Neutraliser::FFmpegError, /boom/)
    end
  end
end
