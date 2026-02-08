require_relative 'parallel_processor'

module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze

    def initialize(replace: false, target_level: nil, profile: 'livingroom', tolerance: 1.0, cache: true, dry_run: false, parallel: true, max_threads: nil, fast_verify: true)
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
    end

    def process(path)
      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
        process_file(path)
      else
        puts "Error: Path '#{path}' does not exist"
        exit 1
      end
    end

    private

    def timestamp
      Time.now.strftime('[%Y-%m-%d %H:%M:%S]')
    end

    def log(message)
      puts "#{timestamp} #{message}"
    end

    def process_directory(dir_path)
      video_files = find_video_files(dir_path)

      if video_files.empty?
        log "No video files found in '#{dir_path}'"
        return
      end

      log "Found #{video_files.length} video file(s)"

      if @parallel_enabled && video_files.length > 1
        process_files_parallel(video_files)
      else
        video_files.each { |file| process_file(file) }
      end
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
        fast_verify: @fast_verify
      }

      start_time = Time.now
      begin
        result = parallel_processor.process_files_parallel(video_files, config)
        elapsed_time = Time.now - start_time

        log "Completed #{result[:completed]} files in #{elapsed_time.round(1)}s"
        log "Errors: #{result[:errors]}" if result[:errors] > 0
      ensure
        parallel_processor.shutdown
      end
    end

    def process_file(file_path)
      unless video_file?(file_path)
        log "Skipping '#{file_path}' - not a supported video format"
        return
      end

      log "Processing: #{file_path}"

      begin
        movie = FFMPEG::Movie.new(file_path)

        unless movie.audio_stream
          log "  No audio track found, skipping"
          return
        end

        measured_data = analyze_loudness(movie)

        if needs_processing?(measured_data)
          if @dry_run
            puts "  [DRY RUN] Would normalize: #{measured_data['input_i'].to_f.round(1)} LUFS → #{@profile[:lufs]} LUFS"
          else
            normalize_file(file_path, measured_data)
          end
        else
          log "  Already at target level, skipping"
        end
      rescue => e
        log "  Error processing file: #{e.message}"
      end
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
        puts "  Fast verification: file already at target level"
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

      FFmpegWrapper.apply_normalization_with_multiple_tracks(
        file_path, output_path, measured_data, audio_tracks, @profile
      )

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
