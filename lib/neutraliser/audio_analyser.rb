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
  end
end