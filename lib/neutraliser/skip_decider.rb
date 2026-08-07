require 'json'
require 'pathname'

module Neutraliser
  # The single authority for "is this file already normalised?".
  #
  # Owns the one sidecar format (`.neutraliser`, size+mtime+profile, never
  # expires) and the one staleness rule. Quick-sample verification (a fast
  # ~30s LUFS estimate, formerly the standalone FastVerifier class) is an
  # internal strategy here, not a parallel authority: it never writes its own
  # marker file. When a quick sample verifies a file as already at target,
  # the verdict is recorded through the same sidecar as a full run would use.
  #
  # Callers that only need the cheap sidecar check (e.g. Processor's
  # pre-analysis short-circuit) use #already_processed?. Callers that also
  # want the quick-sample fallback (e.g. the Analysis Pass) use #skip?.
  class SkipDecider
    FILENAME = '.neutraliser'.freeze

    # Quick-sample duration, in seconds, used to estimate LUFS without a full
    # analysis pass.
    QUICK_SAMPLE_DURATION_S = 30

    # The quick sample is a rough estimate (30s of audio, not the whole
    # file), so it's compared against a tighter tolerance than a full
    # measurement would be — an explicit, documented safety margin (in LU)
    # subtracted from the caller's --tolerance, rather than the tolerance
    # being silently scaled. This is the ONE place that margin is applied.
    QUICK_SAMPLE_SAFETY_MARGIN_LU = 0.2

    def initialize(root_dir, fast_verification: true)
      @path = File.join(root_dir, FILENAME)
      @entries = load
      @fast_verification = fast_verification
    end

    # Cheap pre-check: has this exact file+profile been fully processed
    # before? No ffmpeg involved — just a sidecar lookup.
    def already_processed?(file_path, profile)
      key = tracker_key(file_path)
      entry = @entries[key]
      return false unless entry

      return false unless File.exist?(file_path)
      return false if File.size(file_path) != entry['size']
      return false if File.mtime(file_path).to_i != entry['mtime']
      return false if entry['profile'] != profile[:name]

      true
    end

    # Full skip decision for the Analysis Pass: a sidecar hit, or (when fast
    # verification is enabled) a quick-sample estimate within tolerance.
    # A quick-sample verdict is persisted through #mark_processed so it's
    # available as a cheap sidecar hit on the next run.
    def skip?(file_path, profile, tolerance:)
      return true if already_processed?(file_path, profile)
      return false unless @fast_verification

      if quick_sample_verified?(file_path, profile, tolerance: tolerance)
        Neutraliser.logger.log "  Quick sample: file likely within tolerance"
        mark_processed(file_path, profile)
        true
      else
        false
      end
    end

    def mark_processed(file_path, profile)
      key = tracker_key(file_path)
      @entries[key] = {
        'size' => File.size(file_path),
        'mtime' => File.mtime(file_path).to_i,
        'profile' => profile[:name],
        'processed_at' => Time.now.utc.iso8601
      }
      save
    end

    private

    def quick_sample_verified?(file_path, profile, tolerance:)
      quick_result = FFmpegWrapper.quick_loudness_sample(
        file_path, duration: QUICK_SAMPLE_DURATION_S, target_i: profile[:lufs]
      )
      return false unless quick_result

      difference = (quick_result.input_i - profile[:lufs]).abs
      difference <= quick_sample_tolerance(tolerance)
    rescue StandardError => e
      Neutraliser.logger.log "  Quick check failed (#{e.message}), using full analysis"
      false
    end

    def quick_sample_tolerance(tolerance)
      [tolerance - QUICK_SAMPLE_SAFETY_MARGIN_LU, 0.0].max
    end

    def tracker_key(file_path)
      # Store relative path from the root dir so the sidecar is portable
      root = File.dirname(@path)
      Pathname.new(File.expand_path(file_path)).relative_path_from(Pathname.new(root)).to_s
    end

    def load
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError
      {}
    end

    def save
      File.write(@path, JSON.pretty_generate(@entries))
    rescue StandardError => e
      Neutraliser.logger.log "  Warning: Could not write tracker file: #{e.message}"
    end
  end
end
