require 'json'

module Neutraliser
  # The single authority for "is this file already normalised?".
  #
  # The file's own NEUTRALISER_* tags (Stamp) are the record of truth: a file
  # stamped for the same profile is processed, wherever it now lives and
  # whichever root the run started from. The `.neutraliser` sidecar
  # (size+mtime+profile, never expires) is a cheap cache in front of that
  # probe, refreshed on a tag hit. Quick-sample verification (a fast
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

    # tolerance is this run's --tolerance: a file recorded as "close enough" under
    # a looser one gets looked at again.
    #
    # redo_recipes: the recipes (Recipe) this run was asked to do over. A file
    # made by any other recipe counts as done under the same profile, so a new
    # default never re-levels a library on its own; naming the old recipe
    # (or Recipe::UNVERSIONED) is the deliberate re-run.
    #
    # lra_target is this run's --lra-target. A file only counts as processed if it
    # also meets it: compressed, or measured under the target when it was normalised.
    def initialize(root_dir, fast_verification: true, tolerance: nil, redo_recipes: [], lra_target: nil)
      @path = File.join(root_dir, FILENAME)
      @entries = load
      @fast_verification = fast_verification
      @tolerance = tolerance
      @redo_recipes = redo_recipes
      @lra_target = lra_target
    end

    # Cheap pre-check: has this exact file+profile been fully processed
    # before? A sidecar lookup, then one header-only ffprobe for the tags.
    # No loudness measurement either way.
    def already_processed?(file_path, profile)
      return true if sidecar_hit?(file_path, profile)

      stamp = File.exist?(file_path) ? FFmpegWrapper.read_stamp(file_path) : nil
      return false unless stamp&.profile == profile[:name] && !redo?(stamp.recipe) &&
                          stamp_meets_lra_target?(stamp)

      mark_processed(file_path, profile, recipe: stamp.recipe)
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
        Neutraliser.logger.log '  Quick sample: file likely within tolerance'
        mark_processed(file_path, profile, tolerance: tolerance)
        true
      else
        false
      end
    end

    # tolerance: set when the file was left alone for being close enough, rather
    # than normalised, so that a stricter run isn't bound by this verdict.
    #
    # recipe: the recipe that made (or judged) the file; a tag hit passes the
    # file's own, so the sidecar never claims a newer recipe than the file has.
    # left: a LeftRecord of the levels it was judged close enough on (reason
    # within_tolerance), kept so `report` can place the untouched file.
    def mark_processed(file_path, profile, tolerance: nil, recipe: Recipe::CURRENT, left: nil)
      entry = {
        'size' => File.size(file_path),
        'mtime' => File.mtime(file_path).to_i,
        'profile' => profile[:name],
        'processed_at' => Time.now.utc.iso8601
      }
      entry['recipe'] = recipe if recipe
      entry['tolerance'] = tolerance if tolerance
      entry['left'] = left.to_h_for_entry if left
      entry['lra_target'] = @lra_target if @lra_target
      @entries[tracker_key(file_path)] = entry
      save
    end

    # Records that the file was looked at and left alone (see LeftRecord). It
    # never counts as processed, and overwrites any earlier entry for the file.
    def mark_left(file_path, record)
      @entries[tracker_key(file_path)] = {
        'size' => File.size(file_path),
        'mtime' => File.mtime(file_path).to_i,
        'left' => record.to_h_for_entry,
        'recorded_at' => Time.now.utc.iso8601
      }
      save
    end

    # The record this sidecar holds for the file as it is now, or nil.
    def left_record(file_path)
      entry = @entries[tracker_key(file_path)]
      return nil unless entry && File.exist?(file_path)
      return nil if File.size(file_path) != entry['size'] || File.mtime(file_path).to_i != entry['mtime']

      LeftRecord.from_entry(entry)
    end

    # The nearest record for the file in any `.neutraliser` from its own folder
    # up: the run that wrote it may have started anywhere above. deciders memoises
    # the sidecar read per folder across a batch of lookups.
    def self.left_record_for(file_path, deciders = {})
      dir = File.dirname(File.expand_path(file_path))
      loop do
        record = (deciders[dir] ||= new(dir, fast_verification: false)).left_record(file_path)
        return record if record

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    private

    # The run's own sidecar first, then (when the run started above the file's
    # folder) the sidecar in the file's own folder, where `import-manifest`
    # writes: a record must not depend on how big a run it was made in.
    def sidecar_hit?(file_path, profile)
      entry_matches?(@entries[tracker_key(file_path)], file_path, profile) ||
        entry_matches?(neighbour_entry(file_path), file_path, profile)
    end

    def neighbour_entry(file_path)
      dir = File.dirname(File.expand_path(file_path))
      return nil if dir == File.expand_path(File.dirname(@path))

      @neighbours ||= {}
      @neighbours[dir] ||= load_entries(File.join(dir, FILENAME))
      @neighbours[dir][File.basename(file_path).scrub]
    end

    def entry_matches?(entry, file_path, profile)
      return false unless entry

      return false unless File.exist?(file_path)
      return false if File.size(file_path) != entry['size']
      return false if File.mtime(file_path).to_i != entry['mtime']
      return false if entry['profile'] != profile[:name]
      return false if redo?(entry['recipe'])
      return false if entry['tolerance'] && @tolerance && @tolerance < entry['tolerance']
      return false if @lra_target && !(entry['lra_target'] && entry['lra_target'] <= @lra_target)

      true
    end

    def redo?(recipe) = @redo_recipes.include?(recipe)

    # Without --lra-target any stamp for the profile is enough. With it, a
    # compressed file is done (compression is applied once, not stacked), and a
    # file normalised without compression is done only if its recorded LRA was
    # already within the target. A stamp with no LRA (dynamic, --fast) can't be
    # judged, and loudnorm has already worked on its dynamics.
    def stamp_meets_lra_target?(stamp)
      return true unless @lra_target
      return true if stamp.compressed? || stamp.dynamic? || stamp.measured_lra.nil?

      stamp.measured_lra <= @lra_target + @tolerance.to_f
    end

    def quick_sample_verified?(file_path, profile, tolerance:)
      quick_result = FFmpegWrapper.quick_loudness_sample(
        file_path, duration: QUICK_SAMPLE_DURATION_S, target_i: profile[:lufs],
        audio_index: FFmpegWrapper.primary_audio_index(file_path)
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

    # The path relative to the root, so the sidecar is portable. Scrubbed because
    # a Latin-1 file name on an old NAS isn't valid UTF-8, and one such key in
    # @entries would stop the whole sidecar ever saving as JSON.
    def tracker_key(file_path)
      root = "#{File.expand_path(File.dirname(@path))}/"
      expanded = File.expand_path(file_path)
      (expanded.start_with?(root) ? expanded.delete_prefix(root) : expanded).scrub
    end

    def load = load_entries(@path)

    def load_entries(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError => e
      # Sidecars are an optimisation. Permission errors and transient network
      # filesystem failures should trigger normal analysis, not abort a run.
      Neutraliser.logger.log "  Warning: Could not read tracker file (#{e.class}): #{e.message}"
      {}
    end

    def save
      FileManager.atomic_write(@path, JSON.pretty_generate(@entries))
    rescue StandardError => e
      Neutraliser.logger.log "  Warning: Could not write tracker file (#{e.class}): #{e.message}"
    end
  end
end
