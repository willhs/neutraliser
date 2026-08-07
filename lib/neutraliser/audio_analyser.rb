require 'json'
require 'digest'
require_relative 'fast_verifier'

module Neutraliser
  class AudioAnalyser
    def initialize(cache_enabled: true, fast_verification: true)
      @cache_enabled = cache_enabled
      @cache_manager = CacheManager.new(enabled: cache_enabled)
      @fast_verifier = FastVerifier.new(cache_manager: @cache_manager) if fast_verification
    end

    # The single production entry point for turning a file on disk into a
    # Measurement. Owns the full path: fast-verification short-circuit ->
    # cache lookup -> ffmpeg measurement -> cache write.
    #
    # working_path and cached_as are separate to express staging: the file
    # may be measured from a local working copy while the sidecar cache is
    # keyed by (and lives next to) the original path.
    def analyze(working_path, cached_as:, profile:, tolerance: 1.0)
      if @fast_verifier && !@fast_verifier.needs_analysis?(cached_as, profile, tolerance: tolerance)
        Neutraliser.logger.log "  Fast verification: file already at target level"
        return Measurement.already_at_target(profile)
      end

      if @cache_enabled
        cached = @cache_manager.load_cached_analysis(cached_as, profile)
        if cached
          Neutraliser.logger.log "  Using cached analysis data"
          return cached
        end
      end

      measurement = FFmpegWrapper.measure_loudness(
        working_path,
        target_i: profile[:lufs],
        target_tp: profile[:tp],
        target_lra: profile[:lra]
      )

      @cache_manager.save_analysis(cached_as, profile, measurement) if @cache_enabled

      measurement
    end
  end
end
