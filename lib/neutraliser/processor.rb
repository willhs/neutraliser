require 'json'
require 'time'
require 'pathname'
require 'securerandom'
require_relative 'skip_decider'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = VideoFiles::EXTENSIONS
    # The profile this run aims for, target level applied.
    attr_reader :profile

    MANIFEST_FILENAME = '.neutraliser-run-manifest.jsonl'.freeze
    NORMALIZED_SUFFIX = '_normalized'.freeze
    # Atmos/DTS:X profile names arrived in FFmpeg 7.1. Older ones report none.
    OBJECT_AUDIO_MIN_FFMPEG = [7, 1].freeze
    FAST_REQUIRES_DYNAMIC_MESSAGE = '--fast is single-pass loudnorm and always compresses dynamics; ' \
                                    'add --allow-dynamic (or use the night profile) to accept that'.freeze
    LIMIT_NEEDS_CONSTANT_GAIN_MESSAGE = '--limit-db adds a peak limiter to constant gain; ' \
                                        'it cannot combine with --allow-dynamic, --fast or the night profile'.freeze
    LIMIT_NEEDS_NEWER_FFMPEG_MESSAGE = '--limit-db needs ffmpeg 5.1 or newer (its limiter has no latency option before that); ' \
                                       'upgrade ffmpeg or use the Docker image'.freeze
    LRA_TARGET_NEEDS_CONSTANT_GAIN_MESSAGE = '--lra-target compresses with acompressor and then levels with constant gain; ' \
                                             'it cannot combine with --allow-dynamic, --fast, --fast-verify or the night profile'.freeze
    CENTRE_BOOST_NEEDS_LRA_TARGET_MESSAGE = '--centre-boost is part of --lra-target compression; add --lra-target N'.freeze
    # The only manifest records --resume takes as the last word on a file. Every
    # other outcome depends on something that can change between runs (a flag,
    # free space, the ffmpeg version, or a dry run that did nothing) and goes
    # back through SkipDecider, which costs one probe.
    RESUME_FINAL_REASONS = %w[normalized already_processed no_audio_track unsupported_format].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true,
                   dry_run: false, fast_verify: false, resume: false, fast: false, local_stage: false,
                   allow_dynamic: false, allow_object_audio_loss: false, keep_original_audio: false,
                   limit_db: 0.0, min_gain: nil, allow_codec_change: false, disk_guard: nil, redo_recipes: [],
                   lra_target: nil, centre_boost: nil)
      @replace = replace
      base_profile = profile.is_a?(Hash) ? profile : Profiles.get_profile(profile)
      @profile = if target_level
                   Profiles.custom_profile(target_level.to_f, tp: base_profile[:tp], lra: base_profile[:lra],
                                                              dynamic: base_profile[:dynamic])
                 else
                   base_profile
                 end
      @tolerance = tolerance
      @cache_enabled = cache
      @dry_run = dry_run
      @fast_verify = fast_verify
      @resume = resume
      @fast = fast
      @local_stage = local_stage
      @allow_dynamic = allow_dynamic || @profile[:dynamic] == true
      @allow_object_audio_loss = allow_object_audio_loss
      @keep_original_audio = keep_original_audio
      @allow_codec_change = allow_codec_change
      @disk_guard = disk_guard || DiskGuard.new
      @redo_recipes = Array(redo_recipes).uniq
      Recipe.check_redoable!(@redo_recipes)
      @limit_db = limit_db.to_f
      @min_gain = (min_gain || tolerance).to_f
      @lra_target = lra_target&.to_f
      @centre_boost = centre_boost&.to_f
      raise ArgumentError, FAST_REQUIRES_DYNAMIC_MESSAGE if @fast && !@allow_dynamic
      raise ArgumentError, LIMIT_NEEDS_CONSTANT_GAIN_MESSAGE if @limit_db.positive? && @allow_dynamic
      raise ArgumentError, '--limit-db cannot be negative' if @limit_db.negative?
      raise ArgumentError, LIMIT_NEEDS_NEWER_FFMPEG_MESSAGE if @limit_db.positive? && !FFmpegWrapper.wide_filter_options?

      validate_compression!(fast_verify)

      @stager = LocalStager.new(enabled: local_stage)
    end

    def process(path)
      # Absolute, because ffmpeg reads a relative "Alien: Covenant.mkv" as a URL
      # with the protocol "Alien" (and "http:x.mkv" or "concat:a|b" as the real
      # thing), and never takes one starting with a dash for an option.
      path = File.absolute_path(path)
      warn_if_object_audio_undetectable

      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
        @skip_decider = new_skip_decider(File.dirname(path))
        results, aborted = run_files([path])
        summarize_results(found: 1, queued: 1, resumed: 0, manifest_path: nil, results: results, aborted: aborted)
      else
        log "Error: Path '#{path}' does not exist"
        exit 1
      end
    end

    def process_one(file_path)
      process_file(file_path)
    end

    private

    # --lra-target replaces the constant-gain-only default with "compress, then
    # constant gain", so it refuses every option that already decides the dynamics
    # some other way, and --centre-boost, which only means something inside it.
    def validate_compression!(fast_verify)
      raise ArgumentError, CENTRE_BOOST_NEEDS_LRA_TARGET_MESSAGE if @centre_boost && !@lra_target
      return unless @lra_target

      raise ArgumentError, LRA_TARGET_NEEDS_CONSTANT_GAIN_MESSAGE if @allow_dynamic || @fast || fast_verify
      raise ArgumentError, '--lra-target must be greater than 0' unless @lra_target.positive?
      return unless @centre_boost

      max = Compression::MAX_CENTRE_BOOST_DB
      raise ArgumentError, "--centre-boost must be between 0 and #{max} dB" unless @centre_boost.positive? && @centre_boost <= max
    end

    def log(message)
      Neutraliser.logger.log(message)
    end

    def new_skip_decider(root)
      SkipDecider.new(root, fast_verification: @fast_verify, tolerance: @tolerance, redo_recipes: @redo_recipes,
                           lra_target: @lra_target)
    end

    # Without a version that can name them, an Atmos track looks like plain
    # E-AC3 and would be flattened, which is the one thing this tool promises
    # not to do silently. Says so once per run, and turns a "the name says Atmos"
    # hint from a note into a skip (see check_object_audio).
    def warn_if_object_audio_undetectable
      version = FFmpegWrapper.version
      return if version.nil? || (version <=> OBJECT_AUDIO_MIN_FFMPEG) >= 0

      @object_audio_undetectable = true
      return if @allow_object_audio_loss

      log "Warning: ffmpeg #{version.join('.')} can't recognise Atmos or DTS:X (that needs 7.1+). Files named as such " \
          'are skipped, but any other E-AC3 Atmos track would be flattened to plain channels without notice. ' \
          'Upgrade ffmpeg or use the Docker image.'
    end

    def process_directory(dir_path)
      video_files = find_video_files(dir_path)
      manifest_path = manifest_path_for(dir_path)
      # A dry run decides nothing, so it leaves no record for --resume to trust.
      written_manifest = manifest_path unless @dry_run
      @skip_decider = new_skip_decider(dir_path)

      if video_files.empty?
        log "No video files found in '#{dir_path}'"
        return summarize_results(
          found: 0,
          queued: 0,
          resumed: 0,
          manifest_path: written_manifest,
          results: []
        )
      end

      log "Found #{video_files.length} video file(s)"
      files_to_process, resumed_count = files_for_run(video_files, manifest_path)

      if files_to_process.empty?
        log 'Resume mode: no remaining files to process'
        return summarize_results(
          found: video_files.length,
          queued: 0,
          resumed: resumed_count,
          manifest_path: written_manifest,
          results: []
        )
      end

      files_to_process.each do |file_path|
        append_manifest_entry(written_manifest, file: file_path, status: 'queued')
      end

      results, aborted = run_files(files_to_process, manifest_path: written_manifest)

      summary = summarize_results(
        found: video_files.length,
        queued: files_to_process.length,
        resumed: resumed_count,
        manifest_path: written_manifest,
        results: results,
        aborted: aborted
      )

      log(
        "Run summary: queued=#{summary[:queued]}, done=#{summary[:done]}, " \
        "skipped=#{summary[:skipped]}, failed=#{summary[:failed]}, resumed=#{summary[:resumed]}, " \
        "linear=#{summary[:linear]}, dynamic=#{summary[:dynamic]}, limited=#{summary[:limited]}#{compressed_count(summary)}"
      )
      log_failure_groups(summary)

      summary
    end

    # Runs files in order. A disk-guard abort ends the run: what was done so
    # far is kept, the rest stays queued for the next run.
    #
    # Each file's outcome goes into the run manifest the moment it finishes,
    # not when the whole run does. A multi-hour run over a big library is
    # routinely stopped part-way (Ctrl-C, SIGTERM, a crash); `--resume` reads
    # the manifest, so batching the writes to the end left such a run with a
    # manifest of "queued" lines and nothing to resume from.
    def run_files(files, manifest_path: nil)
      results = []
      files.each do |file|
        result = normalize_file_result(process_one(file), file)
        results << result
        record_result(manifest_path, result) if manifest_path
      end
      [results, false]
    rescue DiskGuard::Abort => e
      log "ABORT: #{e.message}"
      [results, true]
    end

    def files_for_run(video_files, manifest_path)
      return [video_files, 0] unless @resume

      manifest_entries = load_manifest_entries(manifest_path)
      pending_files = video_files.reject do |file_path|
        resume_terminal?(manifest_entries[File.expand_path(file_path).scrub])
      end

      resumed_count = video_files.length - pending_files.length
      log "Resume mode: skipping #{resumed_count} completed file(s)" if resumed_count.positive?

      [pending_files, resumed_count]
    end

    # Only a final outcome, reached by a run asking for the same thing.
    def resume_terminal?(entry)
      return false unless entry && RESUME_FINAL_REASONS.include?(entry['reason'])
      # An earlier run without --redo-recipe called these done; this one was asked to look again.
      return false if @redo_recipes.any? && entry['reason'] == 'already_processed'

      entry['profile'] == @profile[:name] && entry['target_lufs'] == @profile[:lufs] && entry['replace'] == @replace
    end

    def load_manifest_entries(manifest_path)
      return {} unless File.exist?(manifest_path)

      entries = {}
      File.foreach(manifest_path) do |line|
        next if line.strip.empty?

        entry = JSON.parse(line)
        next unless entry['file'] && entry['status']

        entries[entry['file']] = entry
      rescue JSON::ParserError
        next
      end
      entries
    rescue StandardError => e
      log "Warning: Could not read run manifest '#{manifest_path}': #{e.message}"
      {}
    end

    def manifest_path_for(dir_path)
      File.join(dir_path, MANIFEST_FILENAME)
    end

    def record_result(manifest_path, result)
      append_manifest_entry(
        manifest_path,
        file: result[:file],
        status: result[:status].to_s,
        reason: result[:reason],
        message: result[:message],
        normalization_type: result[:normalization_type]
      )
    end

    def append_manifest_entry(manifest_path, file:, status:, reason: nil, message: nil, normalization_type: nil)
      return unless manifest_path

      entry = {
        timestamp: Time.now.utc.iso8601,
        file: File.expand_path(file).scrub,
        status: status,
        profile: @profile[:name],
        target_lufs: @profile[:lufs],
        replace: @replace
      }
      entry[:reason] = reason.to_s if reason
      entry[:message] = message.scrub if message && !message.empty?
      entry[:normalization_type] = normalization_type if normalization_type

      File.open(manifest_path, 'a') { |manifest| manifest.puts(JSON.generate(entry)) }
    rescue StandardError => e
      log "Warning: Could not write run manifest entry (#{e.class}): #{e.message}"
    end

    def summarize_results(found:, queued:, resumed:, manifest_path:, results:, aborted: false)
      done = results.count { |result| result[:status] == :done }
      skipped = results.count { |result| result[:status] == :skipped }
      failed = results.count { |result| result[:status] == :failed }
      linear = results.count { |result| result[:normalization_type] == 'Linear' }
      dynamic = results.count { |result| result[:normalization_type] == 'Dynamic' }
      limited = results.count { |result| result[:normalization_type] == 'Limited' }
      compressed = results.count { |result| result[:normalization_type] == 'Compressed' }
      failures = results.select { |result| result[:status] == :failed }
      not_writable = failures.select { |result| result[:reason] == :not_writable }

      {
        found: found,
        queued: queued,
        resumed: resumed,
        done: done,
        skipped: skipped,
        failed: failed,
        linear: linear,
        dynamic: dynamic,
        limited: limited,
        compressed: compressed,
        aborted: aborted,
        failed_by_reason: failures.map { |result| result[:reason] }.tally,
        not_writable_dirs: not_writable.map { |result| File.dirname(result[:file]) }.uniq.sort,
        manifest_path: manifest_path,
        results: results
      }
    end

    # Whole folders failing the same way (a TV show the NAS user can't write
    # to) read as one line per folder, not hundreds of per-file errors.
    def log_failure_groups(summary)
      return if summary[:failed_by_reason].empty?

      log "Failed by reason: #{summary[:failed_by_reason].map { |reason, count| "#{reason}=#{count}" }.join(', ')}"
      return if summary[:not_writable_dirs].empty?

      log "Not writable — fix permissions on #{summary[:not_writable_dirs].length} folder(s):"
      summary[:not_writable_dirs].each { |dir| log "  #{dir}" }
    end

    # A file with nothing to level: unreadable (a failure, it may be mid-write)
    # or readable but silent of audio (a skip). nil when there is a track.
    def check_audio_stream(file_path, movie)
      return if movie.audio_stream

      unless movie.valid?
        message = 'ffprobe could not read this file; it may be corrupt or still being written'
        log "  Unreadable: #{message}"
        return file_result(file_path, status: :failed, reason: :unreadable, message: message)
      end

      log '  No audio track found, skipping'
      file_result(file_path, status: :skipped, reason: :no_audio_track)
    end

    # Everything per-file happens under these rescues, so one bad file (a name
    # Ruby chokes on, a folder that vanished) is that file's failure, not the end
    # of a library run. Only a disk-guard abort is meant to stop the run.
    def process_file(file_path)
      unless video_file?(file_path)
        log "Skipping '#{file_path}' - not a supported video format"
        return file_result(file_path, status: :skipped, reason: :unsupported_format)
      end

      if already_handled?(file_path)
        log '  Already processed, skipping'
        return file_result(file_path, status: :skipped, reason: :already_processed)
      end

      log "Processing: #{file_path}"
      @source_fingerprint = FileManager.fingerprint(file_path)

      preflight_failure = check_writable(file_path)
      return preflight_failure if preflight_failure

      disk_skip = check_disk_space(file_path)
      return disk_skip if disk_skip

      subtitle_failure = check_subtitles(file_path)
      return subtitle_failure if subtitle_failure

      @stager.with_working_copy(file_path) do |working_path|
        # Binary, because the gem runs a regex over the path, which raises on a
        # name that isn't valid UTF-8 (Latin-1 names are common on older NASes).
        movie = FFMPEG::Movie.new(working_path.b)

        no_audio = check_audio_stream(file_path, movie)
        next no_audio if no_audio

        audio_tracks = FFmpegWrapper.detect_audio_tracks(working_path)
        # Recorded as left alone, never as done: a later --allow-object-audio-loss
        # run (or an ffmpeg that can keep the objects) must still see the file.
        object_audio_skip = check_object_audio(file_path, working_path, FFmpegWrapper.primary_audio_track(audio_tracks))
        next record_outcome(file_path, object_audio_skip) if object_audio_skip

        codec_skip = check_codec_change(file_path, working_path, FFmpegWrapper.primary_audio_track(audio_tracks))
        next record_outcome(file_path, codec_skip) if codec_skip

        result = if @fast
                   process_file_fast(file_path, working_path, audio_tracks)
                 else
                   process_file_two_pass(file_path, working_path, audio_tracks)
                 end

        record_outcome(file_path, result)
      end
    rescue DiskGuard::Abort
      raise
    rescue FFmpegTimeoutError => e
      # Retryable: the subprocess ran out of time, not evidence the file
      # (or the output already committed) is bad.
      log "  Timed out processing file: #{e.message}"
      file_result(file_path, status: :failed, reason: :timeout, message: e.message)
    rescue OutputVerificationError => e
      # The one case where the original must not be replaced - surfaced
      # distinctly so the manifest doesn't read as "same as any other
      # failure" when the real story is "output looked corrupt, original
      # is untouched".
      log "  Output verification failed: #{e.message}"
      file_result(file_path, status: :failed, reason: :output_verification_failed, message: e.message)
    rescue SourceChangedError => e
      log "  Source changed: #{e.message}"
      file_result(file_path, status: :failed, reason: :source_changed, message: e.message)
    rescue FFmpegError => e
      # Non-retryable ffmpeg/ffprobe failure (bad container, unsupported
      # codec, failed probe) - distinct from a timeout so the manifest
      # doesn't conflate "try again" with "this file is broken". The error
      # names the kinds it can recognise (:not_writable,
      # :unsupported_subtitle); the rest stay :ffmpeg_error.
      log "  FFmpeg error processing file: #{e.message}"
      file_result(file_path, status: :failed, reason: e.reason, message: e.message)
    rescue FileManagerError => e
      log "  File management error processing file: #{e.message}"
      file_result(file_path, status: :failed, reason: :file_manager_error, message: e.message)
    rescue StandardError => e
      log "  Error processing file: #{e.message}"
      file_result(file_path, status: :failed, reason: :processing_error, message: e.message)
    end

    # With --replace only the file itself counts. Without it, a finished
    # `_normalized` copy means the job was already done.
    def already_handled?(file_path)
      return false unless @skip_decider
      return true if @skip_decider.already_processed?(file_path, @profile)
      return false if @replace

      copy = generate_output_path(file_path)
      File.exist?(copy) && @skip_decider.already_processed?(copy, @profile)
    end

    # The sidecar says "nothing more to do here", so it only hears a verdict that
    # holds for later runs, about the file that holds the result:
    # - a normalised copy is recorded as the copy, so a later --replace still
    #   does the original;
    # - close enough is recorded with its tolerance, so a stricter run looks again,
    #   and with the levels it was judged on when it was measured, for `report`;
    # - peak-limited, object audio and codec change are recorded as left alone
    #   (LeftRecord), not as done, because --limit-db, --allow-dynamic,
    #   --allow-object-audio-loss or --allow-codec-change can change the answer.
    #   The file is looked at again next run; the record is for `report`;
    # - a dry run isn't recorded, because it did nothing.
    # Returns the result, so a caller can record and return in one step.
    def record_outcome(file_path, result)
      return result if @skip_decider.nil? || @dry_run

      case result[:reason]
      when :normalized
        @skip_decider.mark_processed(@replace ? file_path : generate_output_path(file_path), @profile)
      when :within_tolerance
        @skip_decider.mark_processed(file_path, @profile, tolerance: @tolerance, left: result[:left])
      else
        @skip_decider.mark_left(file_path, result[:left]) if result[:left]
      end
      result
    end

    def process_file_two_pass(original_path, working_path, audio_tracks)
      measurement = analyze_loudness_for_path(working_path, original_path)

      if measurement.silent?
        log '  Primary audio track has no measurable level (silent), skipping'
        file_result(original_path, status: :skipped, reason: :silent)
      elsif compression_needed?(measurement)
        process_file_compressed(original_path, working_path, measurement, audio_tracks)
      elsif peak_limited?(measurement)
        log "  Peak-limited: max useful gain #{gain_plan(measurement).applied.round(2)} dB is under " \
            "#{@min_gain} dB towards target, skipping re-encode"
        file_result(original_path, status: :skipped, reason: :peak_limited,
                                   left: LeftRecord.for(:peak_limited, @profile, measurement: measurement,
                                                                                 message: peak_limited_message(measurement)))
      elsif measurement.needs_normalization?(@profile, tolerance: @tolerance)
        if @dry_run
          log "  [DRY RUN] Would normalize: #{measurement.input_i.round(1)} LUFS → #{@profile[:lufs]} LUFS"
          file_result(original_path, status: :done, reason: :dry_run)
        else
          codec_decision = normalize_file_with_paths(original_path, working_path, measurement, audio_tracks)
          file_result(original_path, status: :done, reason: :normalized,
                                     normalization_type: codec_decision[:normalization_type])
        end
      else
        level = measurement.already_at_target? ? 'by the 30-second sample' : "#{measurement.input_i.round(2)} LUFS"
        log "  Already at target level (#{level}, within #{@tolerance} LU of #{@profile[:lufs]}), skipping"
        file_result(original_path, status: :skipped, reason: :within_tolerance, left: within_tolerance_record(measurement))
      end
    end

    # The sentinel "already at target" measurement has no real levels to keep.
    def within_tolerance_record(measurement)
      return nil if measurement.already_at_target?

      LeftRecord.for(:within_tolerance, @profile, measurement: measurement)
    end

    def peak_limited_message(measurement)
      plan = gain_plan(measurement)
      "peak ceiling allows #{plan.applied.round(2)} dB of the #{plan.desired.round(2)} dB towards #{@profile[:lufs]} LUFS"
    end

    def compression_needed?(measurement)
      return false unless @lra_target

      Compression.needed?(measurement, lra_target: @lra_target, tolerance: @tolerance)
    end

    # --lra-target: the file's loudness range is over the target, so find the
    # gentlest compression that brings it under, level the result to the profile
    # target (peak limiter per --limit-db) and stamp what was done. The plan costs
    # a few extra decodes of the file (see Compression); a dry run does them too,
    # because what it would pick is the thing worth seeing.
    def process_file_compressed(original_path, working_path, measurement, audio_tracks)
      primary = FFmpegWrapper.primary_audio_track(audio_tracks || FFmpegWrapper.detect_audio_tracks(working_path))
      log "  Loudness range #{measurement.input_lra.round(1)} LU is over --lra-target #{@lra_target} " \
          "(+#{@tolerance} tolerance): finding the gentlest compression that reaches it"
      plan = Compression.plan(working_path, primary, measurement, @profile, lra_target: @lra_target,
                                                                            tolerance: @tolerance,
                                                                            centre_boost_db: @centre_boost.to_f,
                                                                            limit_db: @limit_db)
      log_compression_plan(plan, primary)

      if @dry_run
        log "  [DRY RUN] Would compress (#{plan.label}) and level to #{@profile[:lufs]} LUFS"
        return file_result(original_path, status: :done, reason: :dry_run)
      end

      codec_decision = render_normalization(
        original_path, working_path, audio_tracks,
        log_message: "  Compressing (#{plan.rung.name}), then levelling #{plan.after.input_i.round(1)} LUFS " \
                     "to #{@profile[:lufs]} LUFS (#{plan.applied.round(1)} dB)"
      ) do |wp, out, tracks|
        FFmpegWrapper.apply_normalization(wp, out, measurement, @profile, audio_tracks: tracks,
                                                                          keep_original: @keep_original_audio,
                                                                          limit_db: @limit_db, compression: plan)
      end
      file_result(original_path, status: :done, reason: :normalized,
                                 normalization_type: codec_decision[:normalization_type])
    end

    def log_compression_plan(plan, primary)
      rung = plan.rung
      log "  Compression: #{rung.name} (#{rung.ratio}:1, threshold #{rung.threshold_offset_db} dB from the file's level)" \
          "#{centre_note(plan)}; " \
          "LRA #{plan.before.input_lra.round(1)} -> #{plan.after.input_lra.round(1)} LU (measured before the final encode)"
      if @centre_boost && !plan.centre_boost_db.positive?
        log "  Note: --centre-boost skipped, the primary track is not 5.1 (layout: #{primary[:channel_layout] || 'unknown'})"
      end
      log "  Warning: even the strongest compression (#{rung.name}) leaves LRA above --lra-target #{@lra_target}" unless plan.reached?
      log '  Note: peaks will be held by a limiter (--limit-db); this pass changes dynamics a little more' if plan.limited
    end

    def centre_note(plan)
      plan.centre_boost_db.positive? ? ", centre +#{plan.centre_boost_db} dB" : nil
    end

    def compressed_count(summary)
      summary[:compressed].to_i.positive? ? ", compressed=#{summary[:compressed]}" : ''
    end

    # Constant-gain mode only: a file far from target whose peak ceiling
    # leaves less than min_gain dB of gain towards it (or none at all, or a
    # gain the wrong way). Re-encoding it is pure generation loss.
    def peak_limited?(measurement)
      return false if @allow_dynamic || !measurement.needs_normalization?(@profile, tolerance: @tolerance)

      !gain_plan(measurement).worthwhile?(@min_gain)
    end

    # ffmpeg can't encode Atmos/DTS:X object metadata, so re-encoding the
    # primary track flattens it to plain channel audio. Returns a skip result,
    # or nil to carry on (no object audio, or the user accepted the loss).
    def check_object_audio(original_path, working_path, primary_track)
      verdict = ObjectAudio.detect(working_path, primary_track, name: File.basename(original_path))

      if verdict.status == :suspected
        if @object_audio_undetectable && !@allow_object_audio_loss
          log "  Name suggests object audio and this ffmpeg can't check the #{primary_track[:codec]} track, skipping " \
              '(--allow-object-audio-loss to process anyway)'
          return file_result(original_path, status: :skipped, reason: :object_audio, message: 'suspected from the name',
                                            left: LeftRecord.for(:object_audio, @profile, message: 'suspected from the name'))
        end

        log "  Note: name suggests object audio but ffprobe found none on the #{primary_track[:codec]} track, " \
            'processing'
        return nil
      end
      return nil unless verdict.object_audio?

      if @allow_object_audio_loss
        log "  Warning: primary track is #{verdict.profile}; re-encoding drops the object audio " \
            '(--allow-object-audio-loss)'
        return nil
      end

      log "  Object audio (#{verdict.profile}): re-encoding would strip it, skipping " \
          '(--allow-object-audio-loss to process anyway)'
      file_result(original_path, status: :skipped, reason: :object_audio, message: verdict.profile,
                                 left: LeftRecord.for(:object_audio, @profile, message: verdict.profile))
    end

    # Re-encoding to a different codec isn't leveling the volume, it's
    # converting the track. Skipped unless the user accepts it.
    def check_codec_change(original_path, working_path, primary_track)
      return nil if @allow_codec_change

      encoder = FFmpegWrapper.codec_change(primary_track, original_path, working_path)
      return nil unless encoder

      message = "#{primary_track[:codec]} would be re-encoded as #{encoder}"
      log "  Codec change (#{message}), skipping (--allow-codec-change to process anyway)"
      file_result(original_path, status: :skipped, reason: :codec_change, message: message,
                                 left: LeftRecord.for(:codec_change, @profile, message: message))
    end

    # Low space skips this file (a smaller one may still fit); critically low
    # space stops the run. Nothing is recorded, so a later run retries.
    def check_disk_space(file_path)
      return nil if @dry_run || !@disk_guard.enabled?

      dir = output_dir(file_path)
      case @disk_guard.verdict(dir, File.size(file_path))
      when :abort then raise DiskGuard::Abort, "free space on #{dir} is below the abort floor"
      when :skip
        log '  Not enough free space for this file, skipping'
        file_result(file_path, status: :skipped, reason: :low_disk)
      end
    end

    # The output lands beside the original (temp + rename with --replace, a
    # _normalized copy without), so a folder we can't write to fails every
    # file in it - but only after a full analysis pass each. Proving the
    # folder writable first turns that into one cheap check per folder. A dry
    # run writes nothing, so it doesn't need one.
    def check_writable(file_path)
      return nil if @dry_run

      dir = output_dir(file_path)
      blocker = write_blocker(dir)
      return nil unless blocker

      message = "can't write to #{dir} (#{blocker}); fix the folder's permissions"
      log "  Not writable: #{message}"
      file_result(file_path, status: :failed, reason: :not_writable, message: message)
    end

    # Where the output is written: beside the real file when --replace goes
    # through a symlink, since the real file is the one that gets replaced.
    def output_dir(file_path)
      File.dirname(@replace && File.symlink?(file_path) ? File.realpath(file_path) : File.expand_path(file_path))
    end

    # nil when the directory takes a new file, else why not. Memoised per run:
    # permissions are a property of the folder, and a TV season is one folder.
    def write_blocker(dir)
      @write_blockers ||= {}
      return @write_blockers[dir] if @write_blockers.key?(dir)

      @write_blockers[dir] = begin
        probe = File.join(dir, ".neutraliser-write-check-#{Process.pid}-#{SecureRandom.hex(4)}")
        File.open(probe, File::WRONLY | File::CREAT | File::EXCL) { nil }
        File.delete(probe)
        nil
      rescue SystemCallError => e
        SystemCallError.new(nil, e.errno).message # "Permission denied", without Ruby's call site and path
      end
    end

    # Subtitles are copied as-is, never dropped. One ffmpeg can't identify
    # can't be copied either, so the encode would fail after a full analysis
    # pass; fail the file up front with a countable reason instead.
    def check_subtitles(file_path)
      unsupported = FFmpegWrapper.unsupported_subtitles(file_path)
      return nil if unsupported.empty?

      message = "subtitle #{unsupported.join(', ')} can't be copied by this ffmpeg; " \
                'remux or remove it to process this file'
      log "  Unsupported subtitle: #{message}"
      file_result(file_path, status: :failed, reason: :unsupported_subtitle, message: message)
    end

    def gain_plan(measurement)
      GainPlan.for(measurement, @profile, limit_db: @limit_db)
    end

    def process_file_fast(original_path, working_path, audio_tracks)
      if @dry_run
        log "  [DRY RUN] Would normalize (fast single-pass) to #{@profile[:lufs]} LUFS"
        return file_result(original_path, status: :done, reason: :dry_run)
      end

      codec_decision = render_normalization(
        original_path, working_path, audio_tracks,
        log_message: "  Fast mode: single-pass normalization to #{@profile[:lufs]} LUFS"
      ) { |wp, out, tracks| FFmpegWrapper.apply_normalization_single_pass(wp, out, tracks, @profile,
                                                                     keep_original: @keep_original_audio) }

      file_result(original_path, status: :done, reason: :normalized,
                                 normalization_type: codec_decision[:normalization_type])
    end

    # detect_audio_tracks marks a track UNKNOWN_AUDIO_TRACK-shaped when ffprobe
    # succeeded but yielded no real stream data. It's still handed to the
    # encoder/bitrate logic (audio genuinely exists - movie.audio_stream was
    # already checked), but deliberately, with an explicit warning rather
    # than silently trusting fabricated stereo/unknown data.
    def warn_if_audio_track_unknown(audio_tracks)
      primary = FFmpegWrapper.primary_audio_track(audio_tracks)
      return unless primary[:unknown]

      log '  Warning: could not determine audio track format, using conservative defaults'
    end

    def analyze_loudness_for_path(working_path, original_path)
      analyzer = AudioAnalyser.new(
        cache_enabled: @cache_enabled, fast_verification: @fast_verify, skip_decider: @skip_decider
      )
      analyzer.analyze(working_path, cached_as: original_path, profile: @profile, tolerance: @tolerance)
    end

    def normalize_file_with_paths(original_path, working_path, measurement, audio_tracks = nil)
      current_lufs = measurement.input_i
      target_lufs = @profile[:lufs]
      adjustment = target_lufs - current_lufs

      render_normalization(
        original_path, working_path, audio_tracks,
        log_message: "  Current: #{current_lufs.round(1)} LUFS, Target: #{target_lufs} LUFS (#{adjustment.round(1)} LU adjustment)"
      ) do |wp, out, tracks|
        FFmpegWrapper.apply_normalization(wp, out, measurement, @profile, audio_tracks: tracks,
                                                                          allow_dynamic: @allow_dynamic,
                                                                          keep_original: @keep_original_audio,
                                                                          limit_db: @limit_db)
      end
    end

    # Shared render step for both normalization strategies (fast single-pass
    # and two-pass): pick the output path, detect audio tracks, apply the
    # caller-supplied normalization (the only variation point), verify, and
    # commit - with a single ensure-based cleanup for a partially written
    # output_path. The output is always a temp file: nothing takes a final name,
    # or disturbs what already has it, until it has passed verification.
    def render_normalization(original_path, working_path, audio_tracks, log_message:)
      committed = false
      output_path = FileManager.safe_temp_path(temp_anchor(working_path))

      audio_tracks ||= FFmpegWrapper.detect_audio_tracks(working_path)
      warn_if_audio_track_unknown(audio_tracks)
      log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only" if audio_tracks.length > 1

      log log_message
      codec_decision = yield(working_path, output_path, audio_tracks)
      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise OutputVerificationError, 'Output file verification failed - processing aborted'
      end

      mismatch = FileManager.output_mismatch(
        working_path, output_path,
        expected_audio_streams: FFmpegWrapper.output_audio_count(audio_tracks, keep_original: @keep_original_audio),
        primary: FFmpegWrapper.primary_audio_track(audio_tracks)
      )
      raise OutputVerificationError, "Output does not match the source: #{mismatch}" if mismatch

      commit_output(original_path, output_path)
      committed = true
      codec_decision
    ensure
      # ensure (not rescue) so this also runs on Interrupt/SignalException,
      # e.g. Ctrl-C mid-run - rescue => only catches StandardError and would
      # silently leak this temp file on a signal.
      FileUtils.rm_f(output_path) if output_path && !committed && File.exist?(output_path)
    end

    # The temp has to sit on the same filesystem as the file it becomes, for the
    # rename: beside the real file when --replace goes through a symlink. It keeps
    # the link's name, because the extension there decides the output's format.
    def temp_anchor(working_path)
      return working_path unless @replace && File.symlink?(working_path)

      File.join(File.dirname(File.realpath(working_path)), File.basename(working_path))
    end

    def commit_output(original_path, output_path)
      assert_source_unchanged(original_path)
      destination = @replace ? original_path : generate_output_path(original_path)
      @stager.commit(output_path, destination, replace: @replace)
      log @replace ? "  Replaced: #{original_path}" : "  Saved: #{destination}"
    end

    # A file still arriving (a copy over SMB, a download finishing) changes while
    # we work. The output is built from what was there at the start, so renaming
    # it into place would throw away everything written since.
    def assert_source_unchanged(path)
      return if @source_fingerprint.nil? || FileManager.fingerprint(path) == @source_fingerprint

      raise SourceChangedError, 'the file changed while it was being processed, so it was left as it is; ' \
                                'run again once it has finished changing'
    end

    # left: the LeftRecord to persist for a file skipped but not done (see record_outcome).
    def file_result(file_path, status:, reason:, message: nil, normalization_type: nil, left: nil)
      {
        file: File.expand_path(file_path),
        status: status,
        reason: reason,
        message: message,
        normalization_type: normalization_type,
        left: left
      }
    end

    def normalize_file_result(result, fallback_file)
      return result if result.is_a?(Hash) && result[:status]

      file_result(
        fallback_file || 'unknown',
        status: :failed,
        reason: :invalid_result,
        message: 'Processor did not return a valid file result'
      )
    end

    def find_video_files(dir_path)
      VideoFiles.leftover_temps(dir_path).each do |leftover|
        log "Warning: leftover temp file from an interrupted run (safe to delete if no run is active): #{leftover}"
      end

      VideoFiles.under(dir_path).reject { |file| normalized_copy?(file) }
    end

    # film_normalized.mkv beside film.mkv is this tool's output, not another film.
    def normalized_copy?(file_path)
      ext = File.extname(file_path)
      base = File.basename(file_path, ext)
      return false unless base.end_with?(NORMALIZED_SUFFIX)

      File.exist?(File.join(File.dirname(file_path), "#{base.delete_suffix(NORMALIZED_SUFFIX)}#{ext}"))
    end

    def video_file?(file_path)
      VideoFiles.video?(file_path)
    end

    def log_codec_decision(decision)
      return unless decision.is_a?(Hash) && decision[:encoder]

      source = decision[:source_codec].to_s
      source += " (#{decision[:source_profile]})" if decision[:source_profile]
      source += " #{decision[:source_bitrate] / 1000}k" if decision[:source_bitrate].to_i > 0

      target = if decision[:lossless_output]
                 "#{decision[:encoder]} (lossless)"
               else
                 "#{decision[:encoder]} #{decision[:bitrate].to_i / 1000}k"
               end

      log "  Audio: #{source} -> #{target}"
      log "  Normalization: #{decision[:normalization_type]}" if decision[:normalization_type]
      log_dynamic_warning(decision)
      log_limiter_note(decision)
      log_shortfall(decision)
    end

    def log_limiter_note(decision)
      return unless decision[:normalization_type] == 'Limited'

      log "  Note: peaks were held by a limiter (--limit-db #{@limit_db}); this pass changed dynamics slightly"
    end

    def log_dynamic_warning(decision)
      return unless decision[:normalization_type] == 'Dynamic'

      log '  Warning: file went Dynamic - loudnorm compressed its dynamic range'
    end

    def log_shortfall(decision)
      return unless decision[:shortfall_lu].to_f.positive?

      log "  Peak-capped: landed #{decision[:shortfall_lu]} LU short of #{@profile[:lufs]} LUFS target"
    end

    def generate_output_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}#{NORMALIZED_SUFFIX}#{ext}")
    end
  end
end
