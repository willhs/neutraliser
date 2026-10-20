require 'json'
require 'time'
require 'pathname'
require 'securerandom'
require_relative 'skip_decider'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze
    MANIFEST_FILENAME = '.neutraliser-run-manifest.jsonl'.freeze
    FAST_REQUIRES_DYNAMIC_MESSAGE = '--fast is single-pass loudnorm and always compresses dynamics; ' \
                                    'add --allow-dynamic (or use the night profile) to accept that'.freeze
    LIMIT_NEEDS_CONSTANT_GAIN_MESSAGE = '--limit-db adds a peak limiter to constant gain; ' \
                                        'it cannot combine with --allow-dynamic, --fast or the night profile'.freeze
    TERMINAL_RESUME_STATES = %w[done skipped].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true,
                   dry_run: false, fast_verify: true, resume: false, fast: false, local_stage: false,
                   allow_dynamic: false, allow_object_audio_loss: false, keep_original_audio: false,
                   limit_db: 0.0, min_gain: nil, allow_codec_change: false, disk_guard: nil)
      @replace = replace
      @profile = if target_level
                   Profiles.custom_profile(target_level.to_f)
                 elsif profile.is_a?(Hash)
                   profile
                 else
                   Profiles.get_profile(profile)
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
      @limit_db = limit_db.to_f
      @min_gain = (min_gain || tolerance).to_f
      raise ArgumentError, FAST_REQUIRES_DYNAMIC_MESSAGE if @fast && !@allow_dynamic
      raise ArgumentError, LIMIT_NEEDS_CONSTANT_GAIN_MESSAGE if @limit_db.positive? && @allow_dynamic
      raise ArgumentError, '--limit-db cannot be negative' if @limit_db.negative?

      @stager = LocalStager.new(enabled: local_stage)
    end

    def process(path)
      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
        @skip_decider = SkipDecider.new(File.dirname(path), fast_verification: @fast_verify)
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

    def log(message)
      Neutraliser.logger.log(message)
    end

    def process_directory(dir_path)
      video_files = find_video_files(dir_path)
      manifest_path = manifest_path_for(dir_path)
      @skip_decider = SkipDecider.new(dir_path, fast_verification: @fast_verify)

      if video_files.empty?
        log "No video files found in '#{dir_path}'"
        return summarize_results(
          found: 0,
          queued: 0,
          resumed: 0,
          manifest_path: manifest_path,
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
          manifest_path: manifest_path,
          results: []
        )
      end

      files_to_process.each do |file_path|
        append_manifest_entry(manifest_path, file: file_path, status: 'queued')
      end

      raw_results, aborted = run_files(files_to_process)

      results = Array(raw_results).each_with_index.map do |result, index|
        normalize_file_result(result, files_to_process[index])
      end

      results.each do |result|
        append_manifest_entry(
          manifest_path,
          file: result[:file],
          status: result[:status].to_s,
          reason: result[:reason],
          message: result[:message],
          normalization_type: result[:normalization_type]
        )
      end

      summary = summarize_results(
        found: video_files.length,
        queued: files_to_process.length,
        resumed: resumed_count,
        manifest_path: manifest_path,
        results: results,
        aborted: aborted
      )

      log(
        "Run summary: queued=#{summary[:queued]}, done=#{summary[:done]}, " \
        "skipped=#{summary[:skipped]}, failed=#{summary[:failed]}, resumed=#{summary[:resumed]}, " \
        "linear=#{summary[:linear]}, dynamic=#{summary[:dynamic]}, limited=#{summary[:limited]}"
      )
      log_failure_groups(summary)

      summary
    end

    # Runs files in order. A disk-guard abort ends the run: what was done so
    # far is kept, the rest stays queued for the next run.
    def run_files(files)
      results = []
      files.each { |file| results << process_one(file) }
      [results, false]
    rescue DiskGuard::Abort => e
      log "ABORT: #{e.message}"
      [results, true]
    end

    def files_for_run(video_files, manifest_path)
      return [video_files, 0] unless @resume

      manifest_entries = load_manifest_entries(manifest_path)
      pending_files = video_files.reject do |file_path|
        resume_terminal?(manifest_entries[File.expand_path(file_path)])
      end

      resumed_count = video_files.length - pending_files.length
      log "Resume mode: skipping #{resumed_count} completed file(s)" if resumed_count.positive?

      [pending_files, resumed_count]
    end

    # An object-audio skip is only final while the loss is refused: resuming
    # with --allow-object-audio-loss must pick those files back up.
    def resume_terminal?(entry)
      return false unless entry && TERMINAL_RESUME_STATES.include?(entry['status'])

      !(@allow_object_audio_loss && entry['reason'] == 'object_audio')
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

    def append_manifest_entry(manifest_path, file:, status:, reason: nil, message: nil, normalization_type: nil)
      entry = {
        timestamp: Time.now.utc.iso8601,
        file: File.expand_path(file),
        status: status,
        profile: @profile[:name],
        target_lufs: @profile[:lufs]
      }
      entry[:reason] = reason.to_s if reason
      entry[:message] = message if message && !message.empty?
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

    def process_file(file_path)
      unless video_file?(file_path)
        log "Skipping '#{file_path}' - not a supported video format"
        return file_result(file_path, status: :skipped, reason: :unsupported_format)
      end

      if @skip_decider&.already_processed?(file_path, @profile)
        log '  Already processed, skipping'
        return file_result(file_path, status: :skipped, reason: :already_processed)
      end

      log "Processing: #{file_path}"

      preflight_failure = check_writable(file_path)
      return preflight_failure if preflight_failure

      disk_skip = check_disk_space(file_path)
      return disk_skip if disk_skip

      begin
        subtitle_failure = check_subtitles(file_path)
        return subtitle_failure if subtitle_failure

        @stager.with_working_copy(file_path) do |working_path|
          movie = FFMPEG::Movie.new(working_path)

          unless movie.audio_stream
            log '  No audio track found, skipping'
            next file_result(file_path, status: :skipped, reason: :no_audio_track)
          end

          audio_tracks = FFmpegWrapper.detect_audio_tracks(working_path)
          # Not stamped in the sidecar: a later --allow-object-audio-loss run
          # (or an ffmpeg that can keep the objects) must still see the file.
          object_audio_skip = check_object_audio(file_path, working_path, FFmpegWrapper.primary_audio_track(audio_tracks))
          next object_audio_skip if object_audio_skip

          codec_skip = check_codec_change(file_path, working_path, FFmpegWrapper.primary_audio_track(audio_tracks))
          next codec_skip if codec_skip

          result = if @fast
                     process_file_fast(file_path, working_path, audio_tracks)
                   else
                     process_file_two_pass(file_path, working_path, audio_tracks)
                   end

          # A dry run must never stamp the sidecar. Its :dry_run result is
          # status :done ("we handled this file"), but nothing was written —
          # marking it processed would make the real run that follows skip
          # the file as already normalised, silently leaving it untouched.
          @skip_decider&.mark_processed(file_path, @profile) if !@dry_run && %i[done skipped].include?(result[:status])

          result
        end
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
    end

    def process_file_two_pass(original_path, working_path, audio_tracks)
      measurement = analyze_loudness_for_path(working_path, original_path)

      if peak_limited?(measurement)
        log "  Peak-limited: max useful gain #{gain_plan(measurement).applied.round(2)} dB is under " \
            "#{@min_gain} dB towards target, skipping re-encode"
        file_result(original_path, status: :skipped, reason: :peak_limited)
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
        log '  Already at target level, skipping'
        file_result(original_path, status: :skipped, reason: :within_tolerance)
      end
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
      file_result(original_path, status: :skipped, reason: :object_audio, message: verdict.profile)
    end

    # Re-encoding to a different codec isn't leveling the volume, it's
    # converting the track. Skipped unless the user accepts it.
    def check_codec_change(original_path, working_path, primary_track)
      return nil if @allow_codec_change

      encoder = FFmpegWrapper.codec_change(primary_track, original_path, working_path)
      return nil unless encoder

      message = "#{primary_track[:codec]} would be re-encoded as #{encoder}"
      log "  Codec change (#{message}), skipping (--allow-codec-change to process anyway)"
      file_result(original_path, status: :skipped, reason: :codec_change, message: message)
    end

    # Low space skips this file (a smaller one may still fit); critically low
    # space stops the run. Nothing is recorded, so a later run retries.
    def check_disk_space(file_path)
      return nil if @dry_run || !@disk_guard.enabled?

      case @disk_guard.verdict(File.dirname(File.expand_path(file_path)), File.size(file_path))
      when :abort then raise DiskGuard::Abort, "free space on #{File.dirname(File.expand_path(file_path))} is below the abort floor"
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

      dir = File.dirname(File.expand_path(file_path))
      blocker = write_blocker(dir)
      return nil unless blocker

      message = "can't write to #{dir} (#{blocker}); fix the folder's permissions"
      log "  Not writable: #{message}"
      file_result(file_path, status: :failed, reason: :not_writable, message: message)
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
    # output_path.
    def render_normalization(original_path, working_path, audio_tracks, log_message:)
      committed = false
      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

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
        expected_audio_streams: FFmpegWrapper.output_audio_count(audio_tracks, keep_original: @keep_original_audio)
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

    def commit_output(original_path, output_path)
      destination = @replace ? original_path : generate_output_path(original_path)
      @stager.commit(output_path, destination, replace: @replace)
      log @replace ? "  Replaced: #{original_path}" : "  Saved: #{destination}"
    end

    def file_result(file_path, status:, reason:, message: nil, normalization_type: nil)
      {
        file: File.expand_path(file_path),
        status: status,
        reason: reason,
        message: message,
        normalization_type: normalization_type
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
      Dir.glob(File.join(dir_path, '**', '*')).select { |f| video_file?(f) }
    end

    def video_file?(file_path)
      SUPPORTED_FORMATS.include?(File.extname(file_path).downcase)
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

      File.join(dir, "#{basename}_normalized#{ext}")
    end
  end
end
