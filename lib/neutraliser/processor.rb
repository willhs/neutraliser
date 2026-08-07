require 'json'
require 'time'
require 'pathname'
require_relative 'skip_decider'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze
    MANIFEST_FILENAME = '.neutraliser-run-manifest.jsonl'.freeze
    TERMINAL_RESUME_STATES = %w[done skipped].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true, dry_run: false, fast_verify: true, resume: false, fast: false, local_stage: false, linear_only: false)
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
      @linear_only = linear_only
      @stager = LocalStager.new if local_stage
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
        log "Resume mode: no remaining files to process"
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
        "skipped=#{summary[:skipped]}, failed=#{summary[:failed]}, resumed=#{summary[:resumed]}"
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
      log "Warning: Could not write run manifest entry: #{e.message}"
    end

    def summarize_results(found:, queued:, resumed:, manifest_path:, results:)
      done = results.count { |result| result[:status] == :done }
      skipped = results.count { |result| result[:status] == :skipped }
      failed = results.count { |result| result[:status] == :failed }

      {
        found: found,
        queued: queued,
        resumed: resumed,
        done: done,
        skipped: skipped,
        failed: failed,
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
        log "  Already processed, skipping"
        return file_result(file_path, status: :skipped, reason: :already_processed)
      end

      log "Processing: #{file_path}"

      begin
        working_path = file_path
        if @local_stage
          working_path = @stager.stage_in(file_path)
        end

        movie = FFMPEG::Movie.new(working_path)

        unless movie.audio_stream
          log "  No audio track found, skipping"
          @stager&.cleanup(working_path) if @local_stage
          return file_result(file_path, status: :skipped, reason: :no_audio_track)
        end

        if @fast
          result = process_file_fast(file_path, working_path)
        else
          result = process_file_two_pass(file_path, working_path, movie)
        end

        @stager&.cleanup(working_path) if @local_stage

        if result[:status] == :done || result[:status] == :skipped
          @skip_decider&.mark_processed(file_path, @profile)
        end

        result
      rescue FFmpegTimeoutError => e
        # Retryable: the subprocess ran out of time, not evidence the file
        # (or the output already committed) is bad.
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  Timed out processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :timeout, message: e.message)
      rescue OutputVerificationError => e
        # The one case where the original must not be replaced - surfaced
        # distinctly so the manifest doesn't read as "same as any other
        # failure" when the real story is "output looked corrupt, original
        # is untouched".
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  Output verification failed: #{e.message}"
        file_result(file_path, status: :failed, reason: :output_verification_failed, message: e.message)
      rescue FFmpegError => e
        # Non-retryable ffmpeg/ffprobe failure (bad container, unsupported
        # codec, failed probe) - distinct from a timeout so the manifest
        # doesn't conflate "try again" with "this file is broken".
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  FFmpeg error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :ffmpeg_error, message: e.message)
      rescue FileManagerError => e
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  File management error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :file_manager_error, message: e.message)
      rescue => e
        @stager&.cleanup(working_path) if @local_stage && working_path != file_path
        log "  Error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :processing_error, message: e.message)
      end
    end

    def process_file_two_pass(original_path, working_path, movie)
      measurement = analyze_loudness_for_path(working_path, original_path)

      if measurement.needs_normalization?(@profile, tolerance: @tolerance)
        if @dry_run
          log "  [DRY RUN] Would normalize: #{measurement.input_i.round(1)} LUFS → #{@profile[:lufs]} LUFS"
          file_result(original_path, status: :done, reason: :dry_run)
        else
          codec_decision = normalize_file_with_paths(original_path, working_path, measurement)
          file_result(original_path, status: :done, reason: :normalized, normalization_type: codec_decision[:normalization_type])
        end
      else
        log "  Already at target level, skipping"
        file_result(original_path, status: :skipped, reason: :within_tolerance)
      end
    end

    def process_file_fast(original_path, working_path)
      if @dry_run
        log "  [DRY RUN] Would normalize (fast single-pass) to #{@profile[:lufs]} LUFS"
        return file_result(original_path, status: :done, reason: :dry_run)
      end

      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

      audio_tracks = FFmpegWrapper.detect_audio_tracks(working_path)
      warn_if_audio_track_unknown(audio_tracks)
      if audio_tracks.length > 1
        log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
      end

      log "  Fast mode: single-pass normalization to #{@profile[:lufs]} LUFS"

      codec_decision = FFmpegWrapper.apply_normalization_single_pass(
        working_path, output_path, audio_tracks, @profile
      )

      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise OutputVerificationError, "Output file verification failed - processing aborted"
      end

      commit_output(original_path, working_path, output_path)
      file_result(original_path, status: :done, reason: :normalized, normalization_type: codec_decision[:normalization_type])
    rescue => e
      FileUtils.rm_f(output_path) if output_path && File.exist?(output_path)
      raise e
    end

    # detect_audio_tracks marks a track UNKNOWN_AUDIO_TRACK-shaped when ffprobe
    # succeeded but yielded no real stream data. It's still handed to the
    # encoder/bitrate logic (audio genuinely exists - movie.audio_stream was
    # already checked), but deliberately, with an explicit warning rather
    # than silently trusting fabricated stereo/unknown data.
    def warn_if_audio_track_unknown(audio_tracks)
      return unless audio_tracks.first && audio_tracks.first[:unknown]

      log "  Warning: could not determine audio track format, using conservative defaults"
    end

    def analyze_loudness_for_path(working_path, original_path)
      analyzer = AudioAnalyser.new(
        cache_enabled: @cache_enabled, fast_verification: @fast_verify, skip_decider: @skip_decider
      )
      analyzer.analyze(working_path, cached_as: original_path, profile: @profile, tolerance: @tolerance)
    end

    def normalize_file_with_paths(original_path, working_path, measurement)
      output_path = if @replace
                      FileManager.safe_temp_path(working_path)
                    else
                      generate_output_path(working_path)
                    end

      current_lufs = measurement.input_i
      target_lufs = @profile[:lufs]
      adjustment = target_lufs - current_lufs

      audio_tracks = FFmpegWrapper.detect_audio_tracks(working_path)
      warn_if_audio_track_unknown(audio_tracks)
      if audio_tracks.length > 1
        log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
      end

      log "  Current: #{current_lufs.round(1)} LUFS, Target: #{target_lufs} LUFS (#{adjustment.round(1)} LU adjustment)"

      codec_decision = FFmpegWrapper.apply_normalization(
        working_path, output_path, measurement,
        target_i: @profile[:lufs], target_tp: @profile[:tp], target_lra: @profile[:lra],
        audio_tracks: audio_tracks, linear_only: @linear_only
      )

      log_codec_decision(codec_decision)

      unless FileManager.verify_file_integrity(output_path)
        raise OutputVerificationError, "Output file verification failed - processing aborted"
      end

      commit_output(original_path, working_path, output_path)
      codec_decision
    rescue => e
      FileUtils.rm_f(output_path) if output_path && File.exist?(output_path)
      raise e
    end

    def commit_output(original_path, working_path, output_path)
      if @replace
        if @local_stage
          @stager.stage_out(output_path, original_path)
          @stager.cleanup(output_path)
        else
          FileManager.atomic_replace(output_path, original_path)
        end
        log "  Replaced: #{original_path}"
      else
        dest = generate_output_path(original_path)
        if @local_stage
          @stager.stage_out(output_path, dest)
          @stager.cleanup(output_path)
        end
        log "  Saved: #{dest}"
      end
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
    end

    def generate_output_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}_normalized#{ext}")
    end

  end
end
