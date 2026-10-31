module Neutraliser
  # Raised when the analyzer can't reach or authenticate against the Plex
  # server. Library code raises rather than exiting — the CLI owns the
  # process exit code.
  class PlexAnalyzerError < StandardError; end

  class PlexAnalyzer
    # A title is judged from this many short windows spread across its runtime
    # (at these fractions of it), not one contiguous slice: a single window
    # reads wherever it lands, and a film's middle can sit 3 LU under its
    # whole. Windows are energy-combined by LoudnessEstimate. A title this
    # short in total is simply read in full.
    SAMPLE_POSITIONS = [0.1, 0.3, 0.5, 0.7, 0.9].freeze
    STREAM_SAMPLE_DURATION_S = 60
    UNCLEAR_ROWS_SHOWN = 25
    ADJUSTMENT_LABELS = {
      ok: 'OK', too_loud: 'Too Loud', too_quiet: 'Too Quiet', unclear: 'Unclear'
    }.freeze
    READ_IN_FULL_BELOW_S = SAMPLE_POSITIONS.size * STREAM_SAMPLE_DURATION_S

    attr_reader :server_url, :token, :library_name, :output_format, :sample_percent, :profile, :tolerance, :full

    def initialize(server_url:, token: nil, library_name: nil, output_format: 'table',
                   sample_percent: 100, profile: Profiles.default_profile, tolerance: 1.0, full: false)
      @server_url = server_url
      @token = token
      @library_name = library_name
      @output_format = output_format
      @sample_percent = sample_percent
      @profile = profile.is_a?(Hash) ? profile : Profiles.get_profile(profile)
      @tolerance = tolerance
      @full = full
      @plex_server = nil
    end

    def analyze
      log '🎵 Starting Plex library audio analysis...'

      connect_to_plex
      libraries = discover_video_libraries

      if libraries.empty?
        log '❌ No video libraries found on Plex server'
        return
      end

      results = analyze_libraries(libraries)
      generate_report(results)
    end

    private

    def log(message)
      Neutraliser.logger.log(message)
    end

    def connect_to_plex
      @server_url = resolve_server_url
      log "🔌 Connecting to Plex server at #{@server_url}..."

      @auth_token = resolve_token
      unless @auth_token
        raise PlexAnalyzerError, 'No Plex token found! Create a .env file with PLEX_TOKEN=your_token_here, ' \
                                 "or get your token from #{@server_url}/web/index.html#!/settings/account"
      end

      log '🔍 Testing connection...'
      response = make_plex_request('/library/sections')

      unless response.code == '200'
        raise PlexAnalyzerError, "Connection failed: HTTP #{response.code} - #{response.message}"
      end

      sections_data = JSON.parse(response.body)
      section_count = sections_data.dig('MediaContainer', 'size') || 0
      log '✅ Connected to Plex server successfully'
      log "📚 Found #{section_count} library sections"
      @connected = true
    end

    def make_plex_request(path)
      uri = URI.parse(@server_url + path)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')

      request = Net::HTTP::Get.new(uri)
      request['X-Plex-Token'] = @auth_token
      request['Accept'] = 'application/json'

      http.request(request)
    end

    def resolve_server_url
      # Priority: CLI option > .env file > default
      return server_url if server_url != 'http://localhost:32400'

      env_url = ENV.fetch('PLEX_SERVER_URL', nil)
      if env_url && !env_url.strip.empty?
        log '🌐 Using server URL from .env file'
        return env_url.strip
      end

      server_url
    end

    def resolve_token
      # Priority: explicit token parameter > .env file
      return token if token

      env_token = ENV.fetch('PLEX_TOKEN', nil)
      if env_token && !env_token.strip.empty?
        log '🔑 Using token from .env file'
        return env_token.strip
      end

      nil
    end

    def discover_video_libraries
      log '📚 Discovering video libraries...'

      response = make_plex_request('/library/sections')
      raise PlexAnalyzerError, "Failed to get libraries: HTTP #{response.code}" unless response.code == '200'

      data = JSON.parse(response.body)
      all_libraries = data.dig('MediaContainer', 'Directory') || []

      # Filter to video libraries (movie and show types)
      video_libraries = all_libraries.select { |lib| %w[movie show].include?(lib['type']) }

      if library_name
        selected_library = video_libraries.find { |lib| lib['title'].downcase == library_name.downcase }
        unless selected_library
          available = video_libraries.map { |lib| "#{lib['title']} (#{lib['type']})" }.join(', ')
          raise PlexAnalyzerError, "Library '#{library_name}' not found. Available libraries: #{available}"
        end

        video_libraries = [selected_library]
        log "🎯 Analyzing specific library: #{selected_library['title']}"
      else
        log "📋 Found #{video_libraries.length} video libraries:"
        video_libraries.each { |lib| log "   - #{lib['title']} (#{lib['type']})" }
      end

      video_libraries
    end

    def analyze_libraries(libraries)
      all_results = []

      libraries.each do |library|
        library_results = analyze_library(library)
        all_results.concat(library_results)
      end

      all_results
    end

    def analyze_library(library)
      log "\n🔍 Analyzing library: #{library['title']}"

      # Get all media items from the library using Plex API
      response = make_plex_request("/library/sections/#{library['key']}/all")
      unless response.code == '200'
        log "❌ Failed to get library contents: HTTP #{response.code}"
        return []
      end

      data = JSON.parse(response.body)
      all_items = data.dig('MediaContainer', 'Metadata') || []

      # Apply sampling if requested
      if sample_percent < 100
        sample_size = (all_items.size * sample_percent / 100.0).ceil
        all_items = all_items.sample(sample_size)
        log "📊 Sampling #{sample_size} items (#{sample_percent}% of #{all_items.size} total)"
      end

      results = []
      processed = 0

      all_items.each do |item|
        result = analyze_media_item(item, library['type'])
        results << result if result
        processed += 1

        log "   ⏳ Processed #{processed}/#{all_items.size} items..." if processed % 25 == 0
      rescue StandardError => e
        log "   ❌ Error analyzing #{item['title']}: #{e.message}"
      end

      log "✅ Completed analysis of #{library['title']}: #{results.size} valid results"
      results
    end

    def analyze_media_item(item, library_type)
      title = item['title'] || 'Unknown Title'

      streaming_url = get_plex_streaming_url(item)
      return nil unless streaming_url

      content_type = determine_content_type(item, library_type)

      estimate = estimate_loudness(item, streaming_url)
      return nil unless estimate

      verdict = estimate.verdict(@profile[:lufs], @tolerance)

      {
        title: title,
        file_path: streaming_url,
        library_type: library_type,
        content_type: content_type,
        current_level: estimate.level,
        target_level: @profile[:lufs],
        level_difference: estimate.level - @profile[:lufs],
        level_range: [estimate.range.begin, estimate.range.end],
        measured: estimate.exact? ? 'full' : 'sampled',
        verdict: verdict,
        needs_adjustment: %i[too_loud too_quiet].include?(verdict),
        adjustment_type: ADJUSTMENT_LABELS.fetch(verdict)
      }
    rescue StandardError => e
      log "   ❌ Error analyzing #{title}: #{e.message}"
      nil
    end

    def get_plex_streaming_url(item)
      # Get the media part key for streaming
      media_array = item['Media']
      return nil unless media_array && media_array.is_a?(Array) && media_array.first

      parts_array = media_array.first['Part']
      return nil unless parts_array && parts_array.is_a?(Array) && parts_array.first

      part_key = parts_array.first['key']
      return nil unless part_key

      # No token in the URL — kept out of argv/ps by passing it as an ffmpeg
      # -headers argument instead (see analyze_streaming_audio).
      "#{@server_url}#{part_key}"
    end

    # Builds the title's LoudnessEstimate: read in full when asked (--full) or
    # when the title is short, otherwise energy-combined from windows spread
    # across the runtime. Returns nil when nothing trustworthy was measured,
    # so the title is left out rather than given an invented level.
    def estimate_loudness(item, streaming_url)
      total_s = item['duration'].to_i / 1000.0

      if full || total_s <= READ_IN_FULL_BELOW_S
        # A failed read here raises and is handled by analyze_media_item.
        measurement = analyze_streaming_audio(streaming_url)
        return LoudnessEstimate.exact(measurement.input_i) unless measurement.silent?

        log "   ⚠️  #{item['title']}: no audio signal measured, skipping"
        return nil
      end

      levels = window_offsets(total_s).map { |offset| measure_window(streaming_url, offset) }
      estimate = LoudnessEstimate.sampled(levels)
      log "   ⚠️  #{item['title']}: too few readable audio windows (#{levels.compact.size}), skipping" unless estimate
      estimate
    end

    # Start offsets (seconds) of the sample windows, each centred on one of
    # SAMPLE_POSITIONS. Measuring only a film's opening reads logos and
    # titles several LU quieter than the film (Chariots of Fire: -35.3 LUFS
    # from the first minute against a true -20.0).
    def window_offsets(total_s)
      SAMPLE_POSITIONS.map { |position| (total_s * position) - (STREAM_SAMPLE_DURATION_S / 2.0) }
    end

    # One window's integrated loudness, or nil if it can't be read or heard.
    # Dropping a bad window (rather than failing the title) keeps one flaky
    # seek over HTTP from costing the other four; LoudnessEstimate.sampled
    # refuses to report from too few.
    def measure_window(streaming_url, offset)
      measurement = analyze_streaming_audio(
        streaming_url, start_offset: offset, duration: STREAM_SAMPLE_DURATION_S
      )
      measurement.silent? ? nil : measurement.input_i
    rescue FFmpegError => e
      log "   ⚠️  Skipping an unreadable window: #{e.message.lines.first&.strip}"
      nil
    end

    # Measures loudness straight off the Plex stream via FFmpegWrapper's
    # timeboxed, argv-form executor — no shell string, no temp file, no
    # sentinel-float fallback. A failed/timed-out measurement raises.
    # No duration/start_offset measures the whole stream.
    def analyze_streaming_audio(streaming_url, start_offset: nil, duration: nil)
      FFmpegWrapper.measure_loudness(
        streaming_url,
        start_offset: start_offset,
        target_i: @profile[:lufs],
        target_tp: @profile[:tp],
        target_lra: @profile[:lra],
        input_args: ['-headers', "X-Plex-Token: #{@auth_token}\r\n"],
        duration: duration
      )
    end

    def determine_content_type(_item, library_type)
      case library_type
      when 'movie'
        :movie
      when 'show'
        :tv
      else
        :other
      end
    end

    def generate_report(results)
      log "\n" + ('=' * 80)
      log '🎵 PLEX LIBRARY AUDIO ANALYSIS REPORT'
      log '=' * 80

      if results.empty?
        log '❌ No valid audio analysis results found'
        return
      end

      case output_format.downcase
      when 'table'
        generate_table_report(results)
      when 'csv'
        generate_csv_report(results)
      when 'json'
        generate_json_report(results)
      else
        log "❌ Unknown output format: #{output_format}"
        generate_table_report(results)
      end
    end

    def generate_table_report(results)
      total_files = results.size
      needs_adjustment = results.count { |r| r[:needs_adjustment] }
      unclear = results.select { |r| r[:verdict] == :unclear }
      ok = results.count { |r| r[:verdict] == :ok }
      sampled = results.count { |r| r[:measured] == 'sampled' }
      by_type = results.group_by { |r| r[:content_type] }

      log "\n📊 SUMMARY STATISTICS"
      log "Target: #{@profile[:name]} (#{@profile[:lufs]} LUFS, ±#{@tolerance} LU tolerance)"
      log "Total files analyzed: #{total_files} (#{total_files - sampled} measured in full, #{sampled} sampled)"
      log "Files needing adjustment: #{needs_adjustment} (#{percent(needs_adjustment, total_files)}%)"
      log "Files within target range: #{ok} (#{percent(ok, total_files)}%)"
      log "Can't tell from a sample: #{unclear.size} (#{percent(unclear.size, total_files)}%)"
      log level_distribution(results)
      log sampling_caveat if sampled.positive?

      log "\n📋 BY CONTENT TYPE"
      by_type.each do |type, items|
        needs_adj = items.count { |r| r[:needs_adjustment] }
        not_sure = items.count { |r| r[:verdict] == :unclear }
        log "#{type.to_s.capitalize}: #{items.size} files, #{needs_adj} need adjustment, #{not_sure} unclear"
      end

      problematic_files = results.select { |r| r[:needs_adjustment] }

      log "\n🎬 DETAILED RESULTS (files needing adjustment)"
      if problematic_files.empty?
        log '🎉 No file is clearly outside the acceptable volume range.'
      else
        log results_table(problematic_files)
      end

      log_unclear_section(unclear, sampled: sampled.positive?)

      return if problematic_files.empty?

      log "\n💡 RECOMMENDATIONS"
      too_loud = problematic_files.count { |r| r[:adjustment_type] == 'Too Loud' }
      too_quiet = problematic_files.count { |r| r[:adjustment_type] == 'Too Quiet' }

      log "Files too loud: #{too_loud} (will be reduced in volume)"
      log "Files too quiet: #{too_quiet} (will be increased in volume)"

      log "\nTo normalize these files, run:"
      log "neutraliser process [PATH_TO_PLEX_LIBRARY] --profile #{@profile[:name]} --tolerance #{@tolerance}"
    end

    def log_unclear_section(unclear, sampled:)
      return if unclear.empty?

      shown = unclear.sort_by { |r| -r[:level_difference].abs }.first(UNCLEAR_ROWS_SHOWN)
      log "\n❓ CAN'T TELL FROM A SAMPLE (estimate, and the range the true level could be in)"
      log results_table(shown)
      hidden = unclear.size - shown.size
      log "…and #{hidden} more (use --output-format csv or json for every title)." if hidden.positive?
      return unless sampled

      log "A sample can't settle these. Re-run with --full to measure each title end to end (slow), " \
          'or run `neutraliser process --dry-run` on the files.'
    end

    def percent(count, total)
      (count.to_f / total * 100).round(1)
    end

    def level_distribution(results)
      levels = results.map { |r| r[:current_level] }.sort
      median = levels[levels.size / 2]
      "Estimated levels: lowest #{levels.first.round(1)}, median #{median.round(1)}, " \
        "highest #{levels.last.round(1)} LUFS"
    end

    # Be loud about this: a verdict on a sampled title is only given when the
    # whole range the true level could be in sits on one side of the tolerance
    # band. Everything else is "unclear", not a guess.
    def sampling_caveat
      "ℹ️  Sampled titles are judged from #{SAMPLE_POSITIONS.size} x #{STREAM_SAMPLE_DURATION_S}s windows. " \
        "Against full measurements the true level was up to #{format('%g', LoudnessEstimate::TRUTH_LOUDER_MARGIN_LU)} LU " \
        "louder, or #{format('%g', LoudnessEstimate::TRUTH_QUIETER_MARGIN_LU)} LU quieter, than such a sample reads, so a " \
        "sampled title gets a verdict only when that whole range is clear of ±#{@tolerance} LU of target. " \
        'Otherwise it is listed as unclear. `process` (and --full) measure in full.'
    end

    def results_table(rows)
      Terminal::Table.new do |t|
        t.headings = ['Title', 'Type', 'Current', 'Could be', 'Target', 'Diff', 'Status']
        rows.each do |result|
          low, high = result[:level_range]
          t.add_row [
            result[:title].length > 30 ? "#{result[:title][0..27]}..." : result[:title],
            result[:content_type].to_s.capitalize,
            "#{result[:current_level].round(1)} LUFS",
            result[:measured] == 'full' ? 'measured' : "#{low.round(1)} to #{high.round(1)}",
            "#{result[:target_level].round(1)} LUFS",
            "#{'+' if result[:level_difference] > 0}#{result[:level_difference].round(1)} dB",
            result[:adjustment_type]
          ]
        end
      end.to_s
    end

    def generate_csv_report(results)
      require 'csv'

      filename = "plex_audio_analysis_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv"

      CSV.open(filename, 'w') do |csv|
        csv << ['Title', 'File Path', 'Library Type', 'Content Type', 'Current Level (LUFS)',
                'Target Level (LUFS)', 'Level Difference (dB)', 'Needs Adjustment', 'Adjustment Type',
                'Measured', 'Range Low (LUFS)', 'Range High (LUFS)']

        results.each do |result|
          csv << [
            result[:title],
            result[:file_path],
            result[:library_type],
            result[:content_type],
            result[:current_level].round(2),
            result[:target_level].round(2),
            result[:level_difference].round(2),
            result[:needs_adjustment],
            result[:adjustment_type],
            result[:measured],
            result[:level_range][0].round(2),
            result[:level_range][1].round(2)
          ]
        end
      end

      log "📊 CSV report saved to: #{filename}"
    end

    def generate_json_report(results)
      require 'json'

      report_data = {
        analysis_date: Time.now.iso8601,
        server_url: server_url,
        profile: @profile[:name],
        target_level: @profile[:lufs],
        tolerance: @tolerance,
        total_files: results.size,
        files_needing_adjustment: results.count { |r| r[:needs_adjustment] },
        files_unclear: results.count { |r| r[:verdict] == :unclear },
        results: results
      }

      filename = "plex_audio_analysis_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
      File.write(filename, JSON.pretty_generate(report_data))

      log "📊 JSON report saved to: #{filename}"
    end
  end
end
