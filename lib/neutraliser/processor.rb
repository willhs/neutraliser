require 'json'
require 'time'
require_relative 'parallel_processor'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze
    MANIFEST_FILENAME = '.neutraliser-run-manifest.jsonl'.freeze
    TERMINAL_RESUME_STATES = %w[done skipped].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true, dry_run: false, parallel: true, max_threads: nil, fast_verify: true, resume: false)
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
      @parallel_enabled = parallel
      @max_threads = max_threads
      @fast_verify = fast_verify
      @resume = resume
      @manifest_mutex = Mutex.new
    end

    def process(path)
      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
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

      raw_results = if @parallel_enabled && files_to_process.length > 1
                      process_files_parallel(files_to_process)
                    else
                      files_to_process.map { |file| process_one(file) }
                    end

      results = Array(raw_results).each_with_index.map do |result, index|
        normalize_file_result(result, files_to_process[index])
      end

      results.each do |result|
        append_manifest_entry(
          manifest_path,
          file: result[:file],
          status: result[:status].to_s,
          message: result[:message]
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

    def append_manifest_entry(manifest_path, file:, status:, message: nil)
      entry = {
        timestamp: Time.now.utc.iso8601,
        file: File.expand_path(file),
        status: status,
        profile: @profile[:name],
        target_lufs: @profile[:lufs]
      }
      entry[:message] = message if message && !message.empty?

      @manifest_mutex.synchronize do
        File.open(manifest_path, 'a') { |manifest| manifest.puts(JSON.generate(entry)) }
      end
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

    def process_files_parallel(video_files)
      log "Processing #{video_files.length} files with #{@max_threads || 'auto'} threads"

      parallel_processor = ParallelProcessor.new(max_threads: @max_threads)

      config = {
        replace: @replace,
        profile: @profile,
        tolerance: @tolerance,
        cache: @cache_enabled,
        dry_run: @dry_run,
        fast_verify: @fast_verify,
        resume: false
      }

      start_time = Time.now
      begin
        parallel_result = parallel_processor.process_files_parallel(video_files, config)
        elapsed_time = Time.now - start_time

        log(
          "Parallel worker summary: done=#{parallel_result[:done]}, " \
          "skipped=#{parallel_result[:skipped]}, failed=#{parallel_result[:failed]} (#{elapsed_time.round(1)}s)"
        )

        parallel_result[:results]
      ensure
        parallel_processor.shutdown
      end
    end

    def process_file(file_path)
      unless video_file?(file_path)
        log "Skipping '#{file_path}' - not a supported video format"
        return file_result(file_path, status: :skipped, reason: :unsupported_format)
      end

      log "Processing: #{file_path}"

      begin
        movie = FFMPEG::Movie.new(file_path)

        unless movie.audio_stream
          log "  No audio track found, skipping"
          return file_result(file_path, status: :skipped, reason: :no_audio_track)
        end

        measured_data = analyze_loudness(movie)

        if needs_processing?(measured_data)
          if @dry_run
            log "  [DRY RUN] Would normalize: #{measured_data['input_i'].to_f.round(1)} LUFS → #{@profile[:lufs]} LUFS"
            file_result(file_path, status: :done, reason: :dry_run)
          else
            normalize_file(file_path, measured_data)
            file_result(file_path, status: :done, reason: :normalized)
          end
        else
          log "  Already at target level, skipping"
          file_result(file_path, status: :skipped, reason: :within_tolerance)
        end
      rescue => e
        log "  Error processing file: #{e.message}"
        file_result(file_path, status: :failed, reason: :processing_error, message: e.message)
      end
    end

    def file_result(file_path, status:, reason:, message: nil)
      {
        file: File.expand_path(file_path),
        status: status,
        reason: reason,
        message: message
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

    def analyze_loudness(movie)
      analyzer = AudioAnalyser.new(
        cache_enabled: @cache_enabled,
        use_sidecar: @cache_enabled,       # Use sidecar caching when cache is enabled
        fast_verification: @fast_verify    # Use fast verification setting
      )

      # Quick check if analysis is needed (when fast verification is enabled)
      if @fast_verify && !analyzer.should_analyze_file?(movie.path, @profile, tolerance: @tolerance)
        log "  Fast verification: file already at target level"
        # Return dummy data that indicates no processing needed
        return create_target_level_data(@profile)
      end

      analyzer.analyze_file(movie.path, @profile)
    end

    def create_target_level_data(profile)
      # Return analysis data that indicates file is already at target level
      {
        'input_i' => profile[:lufs],  # Already at target LUFS
        'input_tp' => profile[:tp],
        'input_lra' => profile[:lra],
        'input_thresh' => profile[:lufs] - 10.0,
        'target_offset' => 0.0,       # No offset needed
        'fast_verified' => true
      }
    end

    def needs_processing?(measured_data)
      analyzer = AudioAnalyser.new
      analyzer.needs_normalization?(measured_data, @profile, tolerance: @tolerance)
    end

    def normalize_file(file_path, measured_data)
      output_path = @replace ? FileManager.safe_temp_path(file_path) : generate_output_path(file_path)

      current_lufs = measured_data['input_i'].to_f
      target_lufs = @profile[:lufs]
      adjustment = target_lufs - current_lufs

      # Check for multiple audio tracks
      audio_tracks = detect_audio_tracks(file_path)
      if audio_tracks.length > 1
        log "  Found #{audio_tracks.length} audio tracks, normalizing primary track only"
      end

      log "  Current: #{current_lufs.round(1)} LUFS, Target: #{target_lufs} LUFS (#{adjustment.round(1)} LU adjustment)"

      codec_decision = FFmpegWrapper.apply_normalization_with_multiple_tracks(
        file_path, output_path, measured_data, audio_tracks, @profile
      )

      log_codec_decision(codec_decision)

      # Verify output file integrity before committing changes
      unless FileManager.verify_file_integrity(output_path)
        raise "Output file verification failed - processing aborted"
      end

      if @replace
        FileManager.atomic_replace(output_path, file_path)
        log "  Replaced: #{file_path}"
      else
        log "  Saved: #{output_path}"
      end
    rescue => e
      # Clean up temp file on error
      FileUtils.rm(output_path) if File.exist?(output_path)
      raise e
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
    end

    def generate_temp_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}_temp_#{Time.now.to_i}#{ext}")
    end

    def generate_output_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}_normalized#{ext}")
    end

    def cache_directory
      # For Phase 1, use a simple cache directory in tmp
      # This will be enhanced in Phase 3 with sidecar caching
      tmp_dir = ENV['TMPDIR'] || '/tmp'
      cache_dir = File.join(tmp_dir, 'neutraliser_cache')
      FileUtils.mkdir_p(cache_dir) unless File.exist?(cache_dir)
      cache_dir
    end

    def detect_audio_tracks(file_path)
      FFmpegWrapper.detect_audio_tracks(file_path)
    end

    def cleanup_temp_files
      # Clean up any leftover temp files in the current directory
      Dir.glob("*_neutraliser_*").each do |pattern|
        FileManager.cleanup_temp_files(pattern)
      end
    end
  end
end
