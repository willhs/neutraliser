require 'json'
require 'digest'
require_relative 'fast_verifier'

module Neutraliser
  class AudioAnalyser
    def initialize(cache_enabled: true, use_sidecar: true, fast_verification: true)
      @cache_enabled = cache_enabled
      @use_sidecar = use_sidecar
      @fast_verification = fast_verification
      @cache_manager = CacheManager.new(enabled: cache_enabled) if use_sidecar
      @fast_verifier = FastVerifier.new(cache_manager: @cache_manager) if fast_verification
    end

    def analyze_file(file_path, target_profile)
      # Try sidecar cache first (Phase 3 enhancement)
      if @use_sidecar && @cache_manager
        if cached_result = @cache_manager.load_cached_analysis(file_path, target_profile)
          Neutraliser.logger.log "  Using cached analysis data"
          return cached_result
        end
      end

      # Perform FFmpeg measurement
      measured_data = FFmpegWrapper.measure_loudness(
        file_path,
        target_i: target_profile[:lufs],
        target_tp: target_profile[:tp],
        target_lra: target_profile[:lra]
      )

      # Save to sidecar cache
      if @use_sidecar && @cache_manager
        @cache_manager.save_analysis(file_path, target_profile, measured_data)
      end

      measured_data
    end

    def should_analyze_file?(file_path, target_profile, tolerance: 1.0)
      # Fast verification to avoid expensive analysis when possible
      if @fast_verification && @fast_verifier
        return @fast_verifier.needs_analysis?(file_path, target_profile, tolerance: tolerance)
      end

      # Fallback: check cache only
      if @use_sidecar && @cache_manager
        return @cache_manager.load_cached_analysis(file_path, target_profile).nil?
      end

      # No optimization available
      true
    end

    def needs_normalization?(measured_data, target_profile, tolerance: 1.0)
      current_lufs = measured_data['input_i'].to_f
      target_lufs = target_profile[:lufs]
      (current_lufs - target_lufs).abs > tolerance
    end

    def cleanup_cache_for_file(file_path)
      if @use_sidecar && @cache_manager
        @cache_manager.cleanup_stale_cache(file_path)
      end
    end
  end
end