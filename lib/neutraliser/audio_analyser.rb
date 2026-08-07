require 'json'
require 'digest'
require_relative 'skip_decider'

module Neutraliser
  class AudioAnalyser
    def initialize(cache_enabled: true, fast_verification: true, skip_decider: nil)
      @cache_enabled = cache_enabled
      @cache_manager = CacheManager.new(enabled: cache_enabled)
      @fast_verification = fast_verification
      @skip_decider = skip_decider
    end

    # The single production entry point for turning a file on disk into a
    # Measurement. Owns the full path: cache lookup -> skip decision ->
    # ffmpeg measurement -> cache write.
    #
    # working_path and cached_as are separate to express staging: the file
    # may be measured from a local working copy while the sidecar cache is
    # keyed by (and lives next to) the original path.
    #
    # The cache is checked before the skip decision so a genuine cached
    # measurement is always preferred over the already-at-target sentinel —
    # a skip verdict (sidecar hit or quick sample) never has real numbers to
    # offer, so it must never override real cached data.
    def analyze(working_path, cached_as:, profile:, tolerance: 1.0)
      if @cache_enabled
        cached = @cache_manager.load_cached_analysis(cached_as, profile)
        if cached
          Neutraliser.logger.log "  Using cached analysis data"
          return cached
        end
      end

      if skip_decider_for(cached_as).skip?(cached_as, profile, tolerance: tolerance)
        Neutraliser.logger.log "  Skip decision: file already at target level"
        return Measurement.already_at_target(profile)
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

    private

    # Uses the shared decider passed in by the caller when there is one
    # (Processor always shares its own instance so the sidecar stays
    # consistent across the pre-check and the Analysis Pass). Falls back to
    # a decider scoped to the file's own directory for callers that don't
    # share one in (specs, ad-hoc callers outside Processor).
    def skip_decider_for(cached_as)
      @skip_decider ||= SkipDecider.new(File.dirname(cached_as), fast_verification: @fast_verification)
    end
  end
end
