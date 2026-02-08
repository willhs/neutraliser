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
          File.delete(cache_file)
          return nil
        end

        # Profile compatibility check
        if !profiles_compatible?(cached_data['profile'], profile)
          File.delete(cache_file)
          return nil
        end

        # File modification time check
        if File.mtime(video_path) > File.mtime(cache_file)
          File.delete(cache_file)
          return nil
        end

        # Validate required loudnorm data is present
        required_keys = ['input_i', 'input_tp', 'input_lra', 'input_thresh', 'target_offset']
        unless required_keys.all? { |key| cached_data.key?(key) }
          File.delete(cache_file)
          return nil
        end

        # Return only the loudnorm data, not the cache metadata
        cached_data.select { |key, _| required_keys.include?(key) }

      rescue JSON::ParserError, StandardError => e
        # Corrupt or invalid cache file
        File.delete(cache_file) if File.exist?(cache_file)
        nil
      end
    end

    def save_analysis(video_path, profile, analysis_data)
      return unless @enabled

      cache_file = cache_path(video_path, profile)

      begin
        cache_data = {
          # Core loudnorm data
          'input_i' => analysis_data['input_i'],
          'input_tp' => analysis_data['input_tp'],
          'input_lra' => analysis_data['input_lra'],
          'input_thresh' => analysis_data['input_thresh'],
          'target_offset' => analysis_data['target_offset'],

          # Cache metadata
          'cache_version' => CACHE_VERSION,
          'cached_at' => Time.now.iso8601,
          'video_file' => File.basename(video_path),
          'video_size' => File.size(video_path),
          'video_mtime' => File.mtime(video_path).iso8601,
          'profile' => {
            'name' => profile[:name],
            'lufs' => profile[:lufs],
            'tp' => profile[:tp],
            'lra' => profile[:lra]
          }
        }

        File.write(cache_file, JSON.pretty_generate(cache_data))
      rescue StandardError => e
        # Don't fail processing if caching fails, just warn
        puts "  Warning: Could not save analysis cache: #{e.message}"
      end
    end

    def cleanup_stale_cache(video_path, max_age_days: 30)
      return unless @enabled

      dir = File.dirname(video_path)
      basename = File.basename(video_path, File.extname(video_path))

      # Find all cache files for this video
      cache_pattern = File.join(dir, "#{basename}.loudnorm_*.json")

      Dir.glob(cache_pattern).each do |cache_file|
        begin
          if File.exist?(cache_file)
            age_days = (Time.now - File.mtime(cache_file)) / (24 * 60 * 60)

            if age_days > max_age_days
              File.delete(cache_file)
              puts "  Cleaned up stale cache: #{File.basename(cache_file)}"
            end
          end
        rescue StandardError => e
          puts "  Warning: Could not clean up cache file #{cache_file}: #{e.message}"
        end
      end
    end

    def cache_stats(directory)
      return { enabled: false } unless @enabled

      cache_files = Dir.glob(File.join(directory, "*.loudnorm_*.json"))

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

    def profiles_compatible?(cached_profile, current_profile)
      return false unless cached_profile && current_profile

      # Check if LUFS, TP, and LRA targets match
      cached_profile['lufs'] == current_profile[:lufs] &&
        cached_profile['tp'] == current_profile[:tp] &&
        cached_profile['lra'] == current_profile[:lra]
    end
  end
end
