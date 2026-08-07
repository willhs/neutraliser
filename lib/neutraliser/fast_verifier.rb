require 'json'

module Neutraliser
  class FastVerifier
    # Quick verification strategies to avoid expensive FFmpeg analysis

    def initialize(cache_manager: nil)
      @cache_manager = cache_manager
    end

    def needs_analysis?(file_path, profile, tolerance: 1.0)
      # Strategy 1: Check cache first (existing logic)
      if @cache_manager&.load_cached_analysis(file_path, profile)
        return false # Cache hit - no analysis needed
      end

      # Strategy 2: Check for recent processing markers
      if recently_processed?(file_path, profile)
        Neutraliser.logger.log "  File recently processed for this profile, skipping"
        return false
      end

      # Strategy 3: Fast audio sampling for rough LUFS estimate
      if quick_lufs_check(file_path, profile, tolerance)
        Neutraliser.logger.log "  Quick check shows file likely within tolerance"
        return false
      end

      # Fall back to full analysis
      true
    end

    private

    def recently_processed?(file_path, profile)
      # Check for processing marker files that indicate recent normalization
      marker_file = processing_marker_path(file_path, profile)

      if File.exist?(marker_file)
        # Check if marker is recent (within last 7 days)
        marker_age = Time.now - File.mtime(marker_file)
        if marker_age < (7 * 24 * 60 * 60) # 7 days in seconds
          # Verify file hasn't been modified since marker creation
          return File.mtime(file_path) <= File.mtime(marker_file)
        else
          # Clean up old marker
          File.delete(marker_file) rescue nil
        end
      end

      false
    end

    def quick_lufs_check(file_path, profile, tolerance)
      # Fast 30-second sample analysis instead of full file
      # This gives a rough estimate in ~10-30 seconds instead of 5-15 minutes

      begin
        # Sample 30 seconds from middle of file for quick LUFS estimate
        quick_result = FFmpegWrapper.quick_loudness_sample(file_path,
                                                          duration: 30,
                                                          target_i: profile[:lufs])

        if quick_result
          estimated_lufs = quick_result.input_i
          target_lufs = profile[:lufs]
          difference = (estimated_lufs - target_lufs).abs

          # If quick sample shows it's within tolerance, likely the full file is too
          # Use slightly tighter tolerance for quick check to be conservative
          quick_tolerance = tolerance * 0.8

          if difference <= quick_tolerance
            create_processing_marker(file_path, profile, estimated_lufs)
            return true
          end
        end
      rescue => e
        # If quick check fails, fall back to full analysis
        Neutraliser.logger.log "  Quick check failed (#{e.message}), using full analysis"
      end

      false
    end

    def processing_marker_path(file_path, profile)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      profile_name = profile[:name] || 'custom'
      File.join(dir, ".#{basename}.neutralised_#{profile_name}")
    end

    def create_processing_marker(file_path, profile, estimated_lufs)
      marker_file = processing_marker_path(file_path, profile)

      marker_data = {
        processed_at: Time.now.iso8601,
        profile: profile[:name],
        estimated_lufs: estimated_lufs,
        file_mtime: File.mtime(file_path).iso8601,
        verification_method: 'quick_sample'
      }

      File.write(marker_file, JSON.pretty_generate(marker_data))
    rescue => e
      # Don't fail if marker creation fails
      Neutraliser.logger.log "  Warning: Could not create processing marker: #{e.message}"
    end
  end
end