module Neutraliser
  class CacheCommands < Thor
    desc 'stats PATH', 'Show cache statistics for directory'
    def stats(path)
      unless File.directory?(path)
        puts "Error: #{path} is not a directory"
        exit 1
      end

      cache_manager = CacheManager.new(enabled: true)
      stats = cache_manager.cache_stats(path)

      if stats[:enabled]
        puts "Cache Statistics for #{path}:"
        puts "  Cache files: #{stats[:count]}"
        puts "  Total size: #{stats[:total_size_mb]} MB"
        puts "  Oldest cache: #{stats[:oldest_cache]}" if stats[:oldest_cache]
        puts "  Newest cache: #{stats[:newest_cache]}" if stats[:newest_cache]
      else
        puts "Cache is disabled"
      end
    end

    desc 'clean PATH', 'Clean stale cache files older than 30 days'
    option :max_age, type: :numeric, default: 30, desc: 'Maximum age in days for cache files'
    def clean(path)
      unless File.directory?(path)
        puts "Error: #{path} is not a directory"
        exit 1
      end

      cache_manager = CacheManager.new(enabled: true)

      # Find all video files and clean their caches
      video_files = Dir.glob(File.join(path, '**', '*')).select do |f|
        Processor::SUPPORTED_FORMATS.include?(File.extname(f).downcase)
      end

      cleaned_count = 0
      video_files.each do |video_file|
        begin
          cache_manager.cleanup_stale_cache(video_file, max_age_days: options[:max_age])
          cleaned_count += 1
        rescue => e
          puts "Warning: Could not clean cache for #{video_file}: #{e.message}"
        end
      end

      puts "Cleaned cache files for #{cleaned_count} video files"
    end
  end

  class CLI < Thor
    desc 'process PATH', 'Process video file(s) at PATH'
    option :replace, type: :boolean, default: false, desc: 'Replace original files instead of creating copies'
    option :target_level, type: :numeric, desc: 'Target LUFS level for normalisation (overrides profile)'
    option :profile, type: :string, default: 'livingroom', desc: 'Normalization profile: reference, livingroom, night'
    option :tolerance, type: :numeric, default: 1.0, desc: 'Skip files within this many LU of target'
    option :cache, type: :boolean, default: true, desc: 'Cache analysis results'
    option :dry_run, type: :boolean, default: false, desc: 'Analyze only, do not process files'
    option :parallel, type: :boolean, default: true, desc: 'Enable parallel processing for multiple files'
    option :max_threads, type: :numeric, desc: 'Maximum number of concurrent threads (default: auto)'
    option :fast_verify, type: :boolean, default: true, desc: 'Enable fast verification to reduce analysis time'
    def process(path)
      processor = Processor.new(
        replace: options[:replace],
        target_level: options[:target_level],
        profile: options[:profile],
        tolerance: options[:tolerance],
        cache: options[:cache],
        dry_run: options[:dry_run],
        parallel: options[:parallel],
        max_threads: options[:max_threads],
        fast_verify: options[:fast_verify]
      )

      processor.process(path)
    end

    desc 'analyze-plex', 'Analyze Plex library audio levels'
    option :server_url, type: :string, default: 'http://localhost:32400', desc: 'Plex server URL'
    option :token, type: :string, desc: 'Plex authentication token (overrides .env)'
    option :library, type: :string, desc: 'Specific library to analyze (default: all video libraries)'
    option :output_format, type: :string, default: 'table', desc: 'Report format: table, csv, json'
    option :sample_percent, type: :numeric, default: 100, desc: 'Analyze only N% of files for large libraries'
    def analyze_plex
      analyzer = PlexAnalyzer.new(
        server_url: options[:server_url],
        token: options[:token],
        library_name: options[:library],
        output_format: options[:output_format],
        sample_percent: options[:sample_percent]
      )

      analyzer.analyze
    end

    desc 'profiles', 'List available normalization profiles'
    option :verbose, type: :boolean, aliases: ['-v'], default: false, desc: 'Show detailed profile descriptions'
    def profiles
      puts "Available normalization profiles:"
      puts

      Profiles.list_profiles.each do |name|
        profile = Profiles.get_profile(name)
        lra_display = profile[:lra] >= 50 ? 'unlimited' : profile[:lra]

        puts "  #{name.upcase.ljust(12)} - #{profile[:lufs]} LUFS, #{profile[:tp]} dBTP, LRA #{lra_display}"

        if options[:verbose]
          puts "    #{Profiles.describe_profile(profile)}"
          puts
        end
      end

      unless options[:verbose]
        puts
        puts "Use --verbose for detailed descriptions"
      end

      puts
      puts "Default profile: #{Profiles.default_profile[:name]} (#{Profiles.default_profile[:lufs]} LUFS)"
    end

    desc 'cache SUBCOMMAND', 'Manage analysis cache'
    subcommand 'cache', CacheCommands

    desc 'version', 'Show version'
    def version
      puts "Neutraliser v#{VERSION}"
    end

    default_task :process

    def self.start(given_args = ARGV, config = {})
      args = Array(given_args)

      if args.any?
        first = args.first
        unless first.start_with?('-') || command_known?(first)
          args = ['process', *args]
        end
      end

      super(args, config)
    end

    def self.exit_on_failure?
      true
    end

    def self.command_known?(name)
      all_commands.key?(name) || subcommands.include?(name)
    end
  end
end
