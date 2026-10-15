require 'json'
require 'time'
require 'pathname'
require_relative 'skip_decider'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze
    MANIFEST_FILENAME = '.neutraliser-run-manifest.jsonl'.freeze
    FAST_REQUIRES_DYNAMIC_MESSAGE = '--fast is single-pass loudnorm and always compresses dynamics; ' \
                                    'add --allow-dynamic (or use the night profile) to accept that'.freeze
    TERMINAL_RESUME_STATES = %w[done skipped].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true,
                   dry_run: false, fast_verify: true, resume: false, fast: false, local_stage: false, allow_dynamic: false)
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
      raise ArgumentError, FAST_REQUIRES_DYNAMIC_MESSAGE if @fast && !@allow_dynamic

      @stager = LocalStager.new(enabled: local_stage)
    end

    def process(path)
      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
        @skip_decider = SkipDecider.new(File.dirname(path), fast_verification: @fast_verify)
        summarize_results(
          found: 1,
          queued: 1,
          resumed: 0,
          manifest_path: nil,
          results: [process_one(path)]
        )
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

      raw_results = files_to_process.map { |file| process_one(file) }

      results = Array(raw_results).each_with_index.map do |result, index|
        normalize_file_result(result, files_to_process[index])
      end

      results.each do |result|
        append_manifest_entry(
          manifest_path,
          file: result[:file],
          status: result[:status].to_s,
          message: result[:message],
          normalization_type: result[:normalization_type]
        )
      end

      summary = summarize_results(
        found: video_files.length,
        queued: files_to_process.length,
        resumed: resumed_count,
        manifest_path: manifest_path,
        results: results
      )

      log(
        "Run summary: queued=#{summary[:queued]}, done=#{summary[:done]}, " \
        "skipped=#{summary[:skipped]}, failed=#{summary[:failed]}, resumed=#{summary[:resumed]}, " \
        "linear=#{summary[:linear]}, dynamic=#{summary[:dynamic]}"
      )

      summary
    end

    def files_for_run(video_files, manifest_path)
      return [video_files, 0] unless @resume

      manifest_status = load_manifest_statuses(manifest_path)
      pending_files = video_files.reject do |file_path|
        TERMINAL_RESUME_STATES.include?(manifest_status[File.expand_path(file_path)])
      end

      resumed_count = video_files.length - pending_files.length
      log "Resume mode: skipping #{resumed_count} completed file(s)" if resumed_count.positive?

      [pending_files, resumed_count]
    end

    def load_manifest_statuses(manifest_path)
      return {} unless File.exist?(manifest_path)

      statuses = {}
      File.foreach(manifest_path) do |line|
        next if line.strip.empty?

        entry = JSON.parse(line)
        next unless entry['file'] && entry['status']

        statuses[entry['file']] = entry['status']
      rescue JSON::ParserError
        next
      end
      statuses
    rescue StandardError => e
      log "Warning: Could not read run manifest '#{manifest_path}': #{e.message}"
      {}
    end

    def manifest_path_for(dir_path)
      File.join(dir_path, MANIFEST_FILENAME)
    end

    def append_manifest_entry(manifest_path, file:, status:, message: nil, normalization_type: nil)
      entry = {
        timestamp: Time.now.utc.iso8601,
        file: File.expand_path(file),
        status: status,
        profile: @profile[:name],
        target_lufs: @profile[:lufs]
      }
      entry[:message] = message if message && !message.empty?
      entry[:normalization_type] = normalization_type if normalization_type

      File.open(manifest_path, 'a') { |manifest| manifest.puts(JSON.generate(entry)) }
    rescue StandardError => e
      log "Warning: Could not write run manifest entry (#{e.class}): #{e.message}"
    end

    def summarize_results(found:, queued:, resumed:, manifest_path:, results:)
      done = results.count { |result| result[:status] == :done }
      skipped = results.count { |result| result[:status] == :skipped }
      failed = results.count { |result| result[:status] == :failed }
      linear = results.count { |result| result[:normalization_type] == 'Linear' }
      dynamic = results.count { |result| result[:normalization_type] == 'Dynamic' }

      {
        found: found,
        queued: queued,
        resumed: resumed,
        done: done,
        skipped: skipped,
        failed: failed,
        linear: linear,
        dynamic: dynamic,
        manifest_path: manifest_path,
        results: results
      }
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

      begin
        @stager.with_working_copy(file_path) do |working_path|
          movie = FFMPEG::Movie.new(working_path)

          unless movie.audio_stream
            log '  No audio track found, skipping'
            next file_result(file_path, status: :skipped, reason: :no_audio_track)
          end

          result = if @fast
                     process_file_fast(file_path, working_path)
                   else
                     process_file_two_pass(file_path, working_path, movie)
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
        # doesn't conflate "try again" with "this file is broken".
        log "  FFmpeg error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :ffmpeg_error, message: e.message)
      rescue FileManagerError => e
        log "  File management error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :file_manager_error, message: e.message)
      rescue StandardError => e
        log "  Error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :processing_error, message: e.message)
      end
    end

    def process_file_two_pass(original_path, working_path, _movie)
      measurement = analyze_loudness_for_path(working_path, original_path)

      if peak_limited?(measurement)
        log "  Peak-limited: max safe gain #{applied_gain(measurement).round(2)} dB is within " \
            "tolerance (#{@tolerance}), skipping re-encode"
        file_result(original_path, status: :skipped, reason: :peak_limited)
      elsif measurement.needs_normalization?(@profile, tolerance: @tolerance)
        if @dry_run
          log "  [DRY RUN] Would normalize: #{measurement.input_i.round(1)} LUFS → #{@profile[:lufs]} LUFS"
          file_result(original_path, status: :done, reason: :dry_run)
        else
          codec_decision = normalize_file_with_paths(original_path, working_path, measurement)
          file_result(original_path, status: :done, reason: :normalized,
                                     normalization_type: codec_decision[:normalization_type])
        end
      else
        log '  Already at target level, skipping'
        file_result(original_path, status: :skipped, reason: :within_tolerance)
      end
    end

    # Constant-gain mode only: a file far from target whose peak ceiling
    # leaves no real gain to apply. Re-encoding it is pure generation loss.
    def peak_limited?(measurement)
      return false if @allow_dynamic || !measurement.needs_normalization?(@profile, tolerance: @tolerance)

      applied_gain(measurement).abs <= @tolerance
    end

    def applied_gain(measurement)
      FFmpegWrapper.capped_linear_gain(measurement, @profile[:lufs], @profile[:tp])
    end

    def process_file_fast(original_path, working_path)
      if @dry_run
        log "  [DRY RUN] Would normalize (fast single-pass) to #{@profile[:lufs]} LUFS"
        return file_result(original_path, status: :done, reason: :dry_run)
      end

      codec_decision = render_normalization(
        original_path, working_path,
        log_message: "  Fast mode: single-pass normalization to #{@profile[:lufs]} LUFS"
      ) { |wp, out, tracks| FFmpegWrapper.apply_normalization_single_pass(wp, out, tracks, @profile) }

      file_result(original_path, status: :done, reason: :normalized,
                                 normalization_type: codec_decision[:normalization_type])
    end

    # detect_audio_tracks marks a track UNKNOWN_AUDIO_TRACK-shaped when ffprobe
    # succeeded but yielded no real stream data. It's still handed to the
    # encoder/bitrate logic (audio genuinely exists - movie.audio_stream was
    # already checked), but deliberately, with an explicit warning rather
    # than silently trusting fabricated stereo/unknown data.
    def warn_if_audio_track_unknown(audio_tracks)
      return unless audio_tracks.first && audio_tracks.first[:unknown]

      log '  Warning: could not determine audio track format, using conservative defaults'
    end

    def analyze_loudness_for_path(working_path, original_path)
      analyzer = AudioAnalyser.new(
        cache_enabled: @cache_enabled, fast_verification: @fast_verify, skip_decider: @skip_decider
      )
      analyzer.analyze(working_path, cached_as: original_path, profile: @profile, tolerance: @tolerance)
    end

    def normalize_file_with_paths(original_path, working_path, measurement)
      current_lufs = measurement.input_i
      target_lufs = @profile[:lufs]
      adjustment = target_lufs - current_lufs

      render_normalization(
        original_path, working_path,
        log_message: "  Current: #{current_lufs.round(1)} LUFS, Target: #{target_lufs} LUFS (#{adjustment.round(1)} LU adjustment)"
      ) do |wp, out, tracks|
        FFmpegWrapper.apply_normalization(wp, out, measurement, @profile, audio_tracks: tracks,
                                                                          allow_dynamic: @allow_dynamic)
      end
    end

    # Shared render step for both normalization strategies (fast single-pass
    # and two-pass): pick the output path, detect audio tracks, apply the
    # caller-supplied normalization (the only variation point), verify, and
    # commit - with a single ensure-based cleanup for a partially written
    # output_path.
    def render_normalization(original_path, working_path, log_message:)
      committed = false
      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

      audio_tracks = FFmpegWrapper.detect_audio_tracks(working_path)
      warn_if_audio_track_unknown(audio_tracks)
      log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only" if audio_tracks.length > 1

      log log_message
      codec_decision = yield(working_path, output_path, audio_tracks)
      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise OutputVerificationError, 'Output file verification failed - processing aborted'
      end

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
      source += " #{decision[:source_bitrate] / 1000}k" if decision[:source_bitrate].to_i > 0

      target = if decision[:lossless_output]
                 "#{decision[:encoder]} (lossless)"
               else
                 "#{decision[:encoder]} #{decision[:bitrate].to_i / 1000}k"
               end

      log "  Audio: #{source} -> #{target}"
      log "  Normalization: #{decision[:normalization_type]}" if decision[:normalization_type]
      log_dynamic_warning(decision)
      log_shortfall(decision)
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
