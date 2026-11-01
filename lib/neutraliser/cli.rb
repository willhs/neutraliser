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
        puts 'Cache is disabled'
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
      video_files = VideoFiles.under(path)

      cleaned_count = 0
      video_files.each do |video_file|
        cache_manager.cleanup_stale_cache(video_file, max_age_days: options[:max_age])
        cleaned_count += 1
      rescue StandardError => e
        puts "Warning: Could not clean cache for #{video_file}: #{e.message}"
      end

      puts "Cleaned cache files for #{cleaned_count} video files"

      legacy_marker_count = clean_legacy_markers(path)
      return unless legacy_marker_count.positive?

      puts "Removed #{legacy_marker_count} legacy '.neutralised_<profile>' marker file(s)"
    end

    private

    # The old FastVerifier wrote its own '.{basename}.neutralised_{profile}'
    # marker sidecar alongside the ProcessedTracker '.neutraliser' file and
    # the CacheManager '.loudnorm_{profile}.json' cache. That format is
    # retired now that SkipDecider is the single authority, but files left
    # over from older runs still exist on disk — sweep them up here rather
    # than leaving orphaned sidecars.
    def clean_legacy_markers(path)
      Dir.glob('**/.*.neutralised_*', base: path).count do |relative|
        marker_file = File.join(path, relative)
        File.delete(marker_file)
        true
      rescue StandardError => e
        puts "Warning: Could not remove legacy marker #{marker_file}: #{e.message}"
        false
      end
    end
  end

  class CLI < Thor
    EXIT_LOCK_BUSY = 3
    EXIT_DISK_ABORT = 4
    EXIT_SIGNAL_BASE = 128

    desc 'process PATH', 'Process video file(s) at PATH'
    option :replace, type: :boolean, default: false, desc: 'Replace original files instead of creating copies'
    option :target_level, type: :numeric, desc: 'Target LUFS level for normalisation (overrides profile)'
    option :profile, type: :string, default: 'livingroom', desc: 'Normalization profile: reference, livingroom, night'
    option :tolerance, type: :numeric, default: 1.0, desc: 'Skip files within this many LU of target'
    option :cache, type: :boolean, default: true, desc: 'Cache analysis results'
    option :dry_run, type: :boolean, default: false, desc: 'Analyze only, do not process files'
    option :fast_verify, type: :boolean, default: false,
                         desc: 'Skip a file when a 30-second sample looks within tolerance. Faster, but a sample can misjudge a whole film'
    option :resume, type: :boolean, default: false, desc: 'Resume from previous run manifest and skip completed files'
    option :fast, type: :boolean, default: false, desc: 'Single-pass normalization (faster, slightly less accurate)'
    option :local_stage, type: :boolean, default: false, desc: 'Copy files to local disk before processing'
    option :allow_dynamic, type: :boolean, default: false,
                           desc: 'Allow loudnorm to compress dynamics (default is constant gain; quiet-but-peaky files land shy of target)'
    option :allow_object_audio_loss, type: :boolean, default: false,
                                     desc: 'Re-encode Atmos / DTS:X tracks anyway, losing the objects'
    option :keep_original_audio, type: :boolean, default: false,
                                 desc: 'Keep the untouched original audio as an extra non-default track (reversible)'
    option :limit_db, type: :numeric, default: 0.0,
                      desc: 'Let a peak limiter take up to N dB off overshooting peaks so quiet-but-peaky files can reach target (0 = off, strict constant gain)'
    option :min_gain, type: :numeric,
                      desc: 'Skip a peak-capped file when the gain towards target would be under N dB (default: --tolerance)'
    option :allow_codec_change, type: :boolean, default: false,
                                desc: 'Process tracks whose codec cannot be re-encoded to itself (DTS, TrueHD ... become FLAC/E-AC3)'
    option :min_free_gb, type: :numeric,
                         desc: 'Skip files while the output volume has less than N GiB free (or less than the file size)'
    option :abort_free_gb, type: :numeric,
                           desc: 'Stop the run (exit 4) when the output volume has less than N GiB free'
    option :lock_file, type: :string,
                       desc: 'Only one run at a time per lock file; exit 3 when another run holds it'
    option :redo_recipe, type: :string,
                         desc: "Process again files made by these older recipes: comma-separated numbers, or 'unversioned' for files " \
                               'from before recipes were stamped (e.g. 1,unversioned). Without it a file counts as done whatever ' \
                               'recipe made it'
    option :linear_only, type: :boolean, default: false,
                         desc: 'Deprecated no-op: constant gain is now the default'
    def process(path)
      warn 'Warning: --linear-only is now the default and has no effect' if options[:linear_only]

      processor = build_processor
      summary = run_locked(options[:lock_file]) { processor.process(path) }

      return unless summary.is_a?(Hash)

      puts "Summary: found=#{summary[:found]}, queued=#{summary[:queued]}, resumed=#{summary[:resumed]}, " \
           "done=#{summary[:done]}, skipped=#{summary[:skipped]}, failed=#{summary[:failed]}, " \
           "linear=#{summary[:linear]}, dynamic=#{summary[:dynamic]}, limited=#{summary[:limited]}"
      if summary[:failed_by_reason]&.any?
        puts "Failed by reason: #{summary[:failed_by_reason].map { |reason, count| "#{reason}=#{count}" }.join(', ')}"
      end
      puts "Manifest: #{summary[:manifest_path]}" if summary[:manifest_path]
      exit EXIT_DISK_ABORT if summary[:aborted]
      exit 1 if summary[:failed].to_i.positive?
    rescue FFmpegNotFoundError => e
      raise Thor::Error, "Error: #{e.message}"
    rescue SignalException => e
      # Ctrl-C, `docker stop`, a service stop. By now the running ffmpeg has been
      # stopped and its temp output removed on the way up.
      warn "\nStopped by #{Signal.signame(e.signo)}. The file in progress is untouched; " \
           're-run the same command to carry on.'
      exit EXIT_SIGNAL_BASE + e.signo
    end

    desc 'analyze-plex', 'Analyze Plex library audio levels'
    option :server_url, type: :string, default: 'http://localhost:32400', desc: 'Plex server URL'
    option :token, type: :string, desc: 'Plex authentication token (overrides .env)'
    option :library, type: :string, desc: 'Specific library to analyze (default: all video libraries)'
    option :output_format, type: :string, default: 'table', desc: 'Report format: table, csv, json'
    option :sample_percent, type: :numeric, default: 100, desc: 'Analyze only N% of files for large libraries'
    option :profile, type: :string, default: 'livingroom', desc: 'Normalization profile: reference, livingroom, night'
    option :tolerance, type: :numeric, default: 1.0,
                       desc: 'Flag files within this many LU of target as OK (matches `process --tolerance`)'
    option :full, type: :boolean, default: false,
                  desc: 'Measure every title end to end (accurate, slow: reads each file in full) instead of sampling'
    def analyze_plex
      PlexEnv.load
      analyzer = PlexAnalyzer.new(
        server_url: options[:server_url],
        token: options[:token],
        library_name: options[:library],
        output_format: options[:output_format],
        sample_percent: options[:sample_percent],
        profile: options[:profile],
        tolerance: options[:tolerance],
        full: options[:full]
      )

      analyzer.analyze
    rescue StandardError => e
      Neutraliser.logger.log "❌ Analysis failed: #{e.message}"
      exit 1
    end

    desc 'report PATH', 'Report what neutraliser recorded for each video file, and the share of files you could watch without the remote'
    option :format, type: :string, default: 'summary', enum: Report::FORMATS,
                    desc: 'summary (counts), tsv or json (per-file rows)'
    option :measure, type: :boolean, default: false,
                     desc: 'Read every file for its loudness as it is now (slow: decodes each file) instead of computing it from the records'
    option :profile, type: :string, default: 'livingroom',
                     desc: 'Target for files with no record, which are only judged under --measure'
    option :within, type: :numeric, default: RemoteFreeRate::WITHIN_LU,
                    desc: 'Remote-free: loudness within this many LU of the target'
    option :lra_limit, type: :numeric, default: RemoteFreeRate::LRA_LIMIT,
                       desc: 'Remote-free: loudness range at or under this many LU'
    def report(path)
      raise Thor::Error, "Error: Path '#{path}' does not exist" unless File.exist?(path)

      # A failed tag probe reads as "no tags", so without ffprobe every file would
      # look untouched.
      FFmpegWrapper.version
      report = Report.new(path, measure: options[:measure], profile: Profiles.get_profile(options[:profile]),
                                within_lu: options[:within], lra_limit: options[:lra_limit])
      case options[:format]
      when 'tsv'
        puts report.to_tsv
        warn report.summary
      when 'json' then puts report.to_json
      else puts report.summary
      end
    rescue ArgumentError, FFmpegNotFoundError => e
      raise Thor::Error, "Error: #{e.message}"
    end

    desc 'rate-sample ROOT [ROOT...]', 'Try a recipe on copies of a random sample of files and report its remote-free rate (the library is only read)'
    option :sample, type: :numeric, default: 20, desc: 'How many files to sample, spread evenly over the roots'
    option :seed, type: :numeric, desc: 'Seed for the random sample (printed, so a sample can be repeated)'
    option :plan, type: :boolean, default: false, desc: 'Only list the files that would be copied; copy nothing'
    option :work_dir, type: :string, desc: 'Where to put the copies (default: system temp). Must be outside every root'
    option :keep, type: :boolean, default: false, desc: 'Keep the processed copies instead of deleting them'
    option :measure, type: :boolean, default: true,
                     desc: 'Measure the processed copies (default) or compute levels from their records'
    option :profile, type: :string, default: 'livingroom', desc: 'Recipe: normalization profile'
    option :target_level, type: :numeric, desc: 'Recipe: target LUFS (overrides profile)'
    option :tolerance, type: :numeric, default: 1.0, desc: 'Recipe: skip files within this many LU of target'
    option :allow_dynamic, type: :boolean, default: false, desc: 'Recipe: allow loudnorm to compress dynamics'
    option :limit_db, type: :numeric, default: 0.0, desc: 'Recipe: peak limiter reach in dB (0 = off)'
    option :min_gain, type: :numeric, desc: 'Recipe: skip a peak-capped file when the gain would be under N dB'
    option :allow_codec_change, type: :boolean, default: false, desc: 'Recipe: process DTS / TrueHD anyway'
    option :allow_object_audio_loss, type: :boolean, default: false, desc: 'Recipe: process Atmos / DTS:X anyway'
    option :within, type: :numeric, default: RemoteFreeRate::WITHIN_LU, desc: 'Remote-free: within this many LU of target'
    option :lra_limit, type: :numeric, default: RemoteFreeRate::LRA_LIMIT, desc: 'Remote-free: loudness range at or under N LU'
    def rate_sample(*roots)
      raise Thor::Error, 'Error: give at least one root folder' if roots.empty?

      FFmpegWrapper.version
      harness = RateHarness.new(
        roots: roots, size: options[:sample].to_i, seed: options[:seed]&.to_i, processor_options: recipe_options,
        measure: options[:measure], work_dir: options[:work_dir], keep: options[:keep],
        within_lu: options[:within], lra_limit: options[:lra_limit]
      )
      return print_plan(harness) if options[:plan]

      print_rate(harness.run)
    rescue ArgumentError, RateHarness::Error, FFmpegNotFoundError => e
      raise Thor::Error, "Error: #{e.message}"
    end

    desc 'import-manifest MANIFEST', "Mark files recorded as done in a retired neutralise.sh manifest.jsonl as already processed"
    option :root, type: :string, required: true, desc: "Directory the manifest's relative paths hang off (e.g. /path/to/media)"
    option :profile, type: :string, default: 'livingroom', desc: 'Profile those runs were equivalent to'
    option :trust_legacy, type: :boolean, default: false,
                          desc: 'Also accept old entries that recorded no size/mtime (cannot be checked against the file)'
    option :dry_run, type: :boolean, default: false, desc: 'Count what would be imported, write nothing'
    def import_manifest(manifest)
      raise Thor::Error, "Error: '#{manifest}' does not exist" unless File.file?(manifest)
      raise Thor::Error, "Error: '#{options[:root]}' is not a directory" unless File.directory?(options[:root])

      result = ManifestImport.new(
        manifest, root: options[:root], profile: Profiles.get_profile(options[:profile]),
                  trust_legacy: options[:trust_legacy], dry_run: options[:dry_run]
      ).run
      puts "#{options[:dry_run] ? 'Would import' : 'Imported'}: #{result.imported}"
      puts "Not imported: changed since=#{result.changed}, missing=#{result.missing}, " \
           "legacy (no size/mtime)=#{result.legacy}, other statuses=#{result.ignored}"
    end

    desc 'profiles', 'List available normalization profiles'
    option :verbose, type: :boolean, aliases: ['-v'], default: false, desc: 'Show detailed profile descriptions'
    def profiles
      puts 'Available normalization profiles:'
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
        puts 'Use --verbose for detailed descriptions'
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
        args = ['process', *args] unless first.start_with?('-') || command_known?(first)
      end

      super(args, config)
    end

    def self.exit_on_failure?
      true
    end

    # Thor registers commands under their method names, so `analyze-plex` is
    # stored as `analyze_plex`. Thor resolves the hyphenated form itself, but
    # .start runs before that and would otherwise treat `analyze-plex` as a
    # path and rewrite it to `process analyze-plex`. Check both spellings.
    def self.command_known?(name)
      candidates = [name, name.tr('-', '_')]
      candidates.any? { |c| all_commands.key?(c) || subcommands.include?(c) }
    end

    private

    def gib(value) = value && (value * DiskGuard::GIB).to_i

    def recipe_options
      { profile: options[:profile], target_level: options[:target_level], tolerance: options[:tolerance],
        allow_dynamic: options[:allow_dynamic], limit_db: options[:limit_db], min_gain: options[:min_gain],
        allow_codec_change: options[:allow_codec_change], allow_object_audio_loss: options[:allow_object_audio_loss] }
    end

    def print_plan(harness)
      picks = harness.plan
      puts "Seed: #{harness.seed}"
      picks.each { |pick| puts "#{pick.root}\t#{pick.relative}\t#{(pick.size / (1024.0**2)).round} MiB" }
      puts "Would copy #{picks.size} file(s), #{(picks.sum(&:size) / DiskGuard::GIB.to_f).round(2)} GiB. Nothing copied."
    end

    def print_rate(result)
      report = result.report
      puts "Seed: #{result.seed} (repeat this sample with --seed #{result.seed})"
      report.rows.each do |row|
        pick = result.copies.fetch(row.file)
        puts [File.join(File.basename(pick.root), pick.relative), report.state_text(row), report.levels_text(row),
              report.verdict_text(row)].join("\t")
      end
      puts report.summary
      puts "Copies kept in #{result.work_dir}" if result.work_dir
    end

    # The only place a bad option combination (--fast without --allow-dynamic)
    # surfaces. Anything raised once the run is under way is a real error, not
    # a usage message.
    def build_processor
      guard = DiskGuard.new(min_free: gib(options[:min_free_gb]), abort_free: gib(options[:abort_free_gb]))
      Processor.new(
        replace: options[:replace],
        target_level: options[:target_level],
        profile: options[:profile],
        tolerance: options[:tolerance],
        cache: options[:cache],
        dry_run: options[:dry_run],
        fast_verify: options[:fast_verify],
        resume: options[:resume],
        fast: options[:fast],
        local_stage: options[:local_stage],
        allow_dynamic: options[:allow_dynamic],
        allow_object_audio_loss: options[:allow_object_audio_loss],
        keep_original_audio: options[:keep_original_audio],
        limit_db: options[:limit_db],
        min_gain: options[:min_gain],
        allow_codec_change: options[:allow_codec_change],
        disk_guard: guard,
        redo_recipes: options[:redo_recipe].to_s.split(',').map { |text| Recipe.parse(text) }
      )
    rescue ArgumentError, FileManagerError, SystemCallError => e
      raise Thor::Error, "Error: #{e.message}"
    end

    def run_locked(lock_file, &)
      return yield unless lock_file

      RunLock.hold(lock_file, &)
    rescue RunLock::Busy => e
      warn "Error: #{e.message}"
      exit EXIT_LOCK_BUSY
    rescue RunLock::Unavailable => e
      raise Thor::Error, "Error: #{e.message}"
    end
  end
end
