require 'json'
require 'digest'
require 'time'

module Neutraliser
  class CacheManager
    CACHE_VERSION = '1.1'

    def initialize(enabled: true)
      @enabled = enabled
    end

    def cache_path(video_path, profile)
      dir = File.dirname(video_path)
      basename = File.basename(video_path, File.extname(video_path))
      profile_name = profile[:name] || 'custom'
      cache_name = "#{basename}.loudnorm_#{profile_name}.json"
      File.join(dir, cache_name)
    end

    def load_cached_analysis(video_path, profile)
      return nil unless @enabled

      cache_file = cache_path(video_path, profile)
      return nil unless File.exist?(cache_file)

      begin
        cached_data = JSON.parse(File.read(cache_file))

        # Version compatibility check
        if cached_data['cache_version'] != CACHE_VERSION
          discard_cache(cache_file)
          return nil
        end

        # Profile compatibility check
        unless profiles_compatible?(cached_data['profile'], profile)
          discard_cache(cache_file)
          return nil
        end

        # A measurement only applies to the file it was made from. Comparing
        # mtimes alone hands the old figure to a swapped file with an older
        # date (an *arr upgrade can keep the release's) and to a same-named file
        # with another extension, which shares this cache path.
        unless same_file?(cached_data, video_path)
          discard_cache(cache_file)
          return nil
        end

        # Validate required loudnorm data is present and rebuild the typed
        # Measurement (the cache metadata like cache_version/profile is
        # deliberately dropped here, not carried in the returned value).
        measurement = Measurement.from_cache_h(cached_data)
        unless measurement
          discard_cache(cache_file)
          return nil
        end

        measurement
      rescue StandardError => e
        # Cache I/O is always best-effort. A read-only or temporarily
        # unavailable network filesystem must not block media processing.
        Neutraliser.logger.log "  Warning: Could not read analysis cache (#{e.class}): #{e.message}"
        discard_cache(cache_file)
        nil
      end
    end

    def save_analysis(video_path, profile, measurement)
      return unless @enabled

      cache_file = cache_path(video_path, profile)

      begin
        cache_data = measurement.to_cache_h.merge(
          # Cache metadata
          'cache_version' => CACHE_VERSION,
          'cached_at' => Time.now.iso8601,
          'video_file' => File.basename(video_path).scrub,
          'video_size' => File.size(video_path),
          'video_mtime' => File.mtime(video_path).iso8601,
          'profile' => {
            'name' => profile[:name],
            'lufs' => profile[:lufs],
            'tp' => profile[:tp],
            'lra' => profile[:lra]
          }
        )

        FileManager.atomic_write(cache_file, JSON.pretty_generate(cache_data))
      rescue StandardError => e
        # Don't fail processing if caching fails, just warn
        Neutraliser.logger.log "  Warning: Could not save analysis cache (#{e.class}): #{e.message}"
      end
    end

    def cleanup_stale_cache(video_path, max_age_days: 30)
      return unless @enabled

      dir = File.dirname(video_path)
      basename = File.basename(video_path, File.extname(video_path))

      # Find all cache files for this video. Compared as strings: a film called
      # "Film [1080p]" would be a glob pattern that doesn't match its own name.
      cache_files = Dir.children(dir).select { |name| name.start_with?("#{basename}.loudnorm_") && name.end_with?('.json') }

      cache_files.map { |name| File.join(dir, name) }.each do |cache_file|
        age_days = (Time.now - File.mtime(cache_file)) / (24 * 60 * 60)

        if age_days > max_age_days
          File.delete(cache_file)
          Neutraliser.logger.log "  Cleaned up stale cache: #{File.basename(cache_file)}"
        end
      rescue StandardError => e
        Neutraliser.logger.log "  Warning: Could not clean up cache file #{cache_file}: #{e.message}"
      end
    end

    def cache_stats(directory)
      return { enabled: false } unless @enabled

      cache_files = Dir.glob('*.loudnorm_*.json', base: directory).map { |name| File.join(directory, name) }

      total_size = cache_files.sum { |file| File.size(file) }
      oldest_cache = cache_files.map { |file| File.mtime(file) }.min
      newest_cache = cache_files.map { |file| File.mtime(file) }.max

      {
        enabled: true,
        count: cache_files.length,
        total_size_mb: (total_size / 1024.0 / 1024.0).round(2),
        oldest_cache: oldest_cache,
        newest_cache: newest_cache
      }
    end

    private

    def same_file?(cached_data, video_path)
      cached_data['video_file'] == File.basename(video_path).scrub &&
        cached_data['video_size'] == File.size(video_path) &&
        Time.iso8601(cached_data['video_mtime'].to_s).to_i == File.mtime(video_path).to_i
    end

    def discard_cache(cache_file)
      File.delete(cache_file) if File.exist?(cache_file)
    rescue StandardError => e
      Neutraliser.logger.log "  Warning: Could not remove analysis cache (#{e.class}): #{e.message}"
    end

    def profiles_compatible?(cached_profile, current_profile)
      return false unless cached_profile && current_profile

      # Check if LUFS, TP, and LRA targets match
      cached_profile['lufs'] == current_profile[:lufs] &&
        cached_profile['tp'] == current_profile[:tp] &&
        cached_profile['lra'] == current_profile[:lra]
    end
  end
end
