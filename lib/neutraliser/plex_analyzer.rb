module Neutraliser
  # Raised when the analyzer can't reach or authenticate against the Plex
  # server. Library code raises rather than exiting — the CLI owns the
  # process exit code.
  class PlexAnalyzerError < StandardError; end

  class PlexAnalyzer
    # How much of each stream to sample when measuring loudness — a fast
    # preview across a whole library, not the definitive measurement used by
    # `process` (which analyzes the full file).
    STREAM_SAMPLE_DURATION_S = 60

    attr_reader :server_url, :token, :library_name, :output_format, :sample_percent, :profile, :tolerance

    def initialize(server_url:, token: nil, library_name: nil, output_format: 'table',
                   sample_percent: 100, profile: Profiles.default_profile, tolerance: 1.0)
      @server_url = server_url
      @token = token
      @library_name = library_name
      @output_format = output_format
      @sample_percent = sample_percent
      @profile = profile.is_a?(Hash) ? profile : Profiles.get_profile(profile)
      @tolerance = tolerance
      @plex_server = nil
    end

    def analyze
      log "🎵 Starting Plex library audio analysis..."

      connect_to_plex
      libraries = discover_video_libraries

      if libraries.empty?
        log "❌ No video libraries found on Plex server"
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
        raise PlexAnalyzerError, "No Plex token found! Create a .env file with PLEX_TOKEN=your_token_here, " \
                                  "or get your token from #{@server_url}/web/index.html#!/settings/account"
      end

      log "🔍 Testing connection..."
      response = make_plex_request('/library/sections')

      unless response.code == '200'
        raise PlexAnalyzerError, "Connection failed: HTTP #{response.code} - #{response.message}"
      end

      sections_data = JSON.parse(response.body)
      section_count = sections_data.dig('MediaContainer', 'size') || 0
      log "✅ Connected to Plex server successfully"
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

      env_url = ENV['PLEX_SERVER_URL']
      if env_url && !env_url.strip.empty?
        log "🌐 Using server URL from .env file"
        return env_url.strip
      end

      server_url
    end

    def resolve_token
      # Priority: explicit token parameter > .env file
      return token if token

      env_token = ENV['PLEX_TOKEN']
      if env_token && !env_token.strip.empty?
        log "🔑 Using token from .env file"
        return env_token.strip
      end

      nil
    end

    def discover_video_libraries
      log "📚 Discovering video libraries..."

      response = make_plex_request('/library/sections')
      unless response.code == '200'
        raise PlexAnalyzerError, "Failed to get libraries: HTTP #{response.code}"
      end

      data = JSON.parse(response.body)
      all_libraries = data.dig('MediaContainer', 'Directory') || []

      # Filter to video libraries (movie and show types)
      video_libraries = all_libraries.select { |lib| lib['type'] == 'movie' || lib['type'] == 'show' }

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
        begin
          result = analyze_media_item(item, library['type'])
          results << result if result
          processed += 1

          log "   ⏳ Processed #{processed}/#{all_items.size} items..." if processed % 25 == 0
        rescue => e
          log "   ❌ Error analyzing #{item['title']}: #{e.message}"
        end
      end

      log "✅ Completed analysis of #{library['title']}: #{results.size} valid results"
      results
    end

    def analyze_media_item(item, library_type)
      title = item['title'] || 'Unknown Title'

      streaming_url = get_plex_streaming_url(item)
      return nil unless streaming_url

      content_type = determine_content_type(item, library_type)

      measurement = analyze_streaming_audio(streaming_url)
      return nil unless measurement

      current_level = measurement.input_i
      needs_adjustment = measurement.needs_normalization?(@profile, tolerance: @tolerance)

      {
        title: title,
        file_path: streaming_url,
        library_type: library_type,
        content_type: content_type,
        current_level: current_level,
        target_level: @profile[:lufs],
        level_difference: current_level - @profile[:lufs],
        needs_adjustment: needs_adjustment,
        adjustment_type: adjustment_type(current_level, needs_adjustment)
      }
    rescue => e
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

    # Measures loudness straight off the Plex stream via FFmpegWrapper's
    # timeboxed, argv-form executor — no shell string, no temp file, no
    # sentinel-float fallback. A failed/timed-out measurement raises and is
    # handled by the caller (analyze_media_item), which skips the item.
    def analyze_streaming_audio(streaming_url)
      FFmpegWrapper.measure_loudness(
        streaming_url,
        target_i: @profile[:lufs],
        target_tp: @profile[:tp],
        target_lra: @profile[:lra],
        input_args: ['-headers', "X-Plex-Token: #{@auth_token}\r\n"],
        duration: STREAM_SAMPLE_DURATION_S
      )
    end

    def determine_content_type(item, library_type)
      case library_type
      when 'movie'
        :movie
      when 'show'
        :tv
      else
        :other
      end
    end

    def adjustment_type(current_level, needs_adjustment)
      return 'OK' unless needs_adjustment

      current_level > @profile[:lufs] ? 'Too Loud' : 'Too Quiet'
    end

    def generate_report(results)
      log "\n" + "="*80
      log "🎵 PLEX LIBRARY AUDIO ANALYSIS REPORT"
      log "="*80

      if results.empty?
        log "❌ No valid audio analysis results found"
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
      # Summary statistics
      total_files = results.size
      needs_adjustment = results.count { |r| r[:needs_adjustment] }
      by_type = results.group_by { |r| r[:content_type] }

      log "\n📊 SUMMARY STATISTICS"
      log "Target: #{@profile[:name]} (#{@profile[:lufs]} LUFS, ±#{@tolerance} LU tolerance)"
      log "Total files analyzed: #{total_files}"
      log "Files needing adjustment: #{needs_adjustment} (#{(needs_adjustment.to_f / total_files * 100).round(1)}%)"
      log "Files within target range: #{total_files - needs_adjustment} (#{((total_files - needs_adjustment).to_f / total_files * 100).round(1)}%)"

      log "\n📋 BY CONTENT TYPE"
      by_type.each do |type, items|
        needs_adj = items.count { |r| r[:needs_adjustment] }
        log "#{type.to_s.capitalize}: #{items.size} files, #{needs_adj} need adjustment"
      end

      # Detailed results table
      log "\n🎬 DETAILED RESULTS (files needing adjustment)"
      problematic_files = results.select { |r| r[:needs_adjustment] }

      if problematic_files.empty?
        log "🎉 All files are within acceptable volume ranges!"
        return
      end

      table = Terminal::Table.new do |t|
        t.headings = ['Title', 'Type', 'Current', 'Target', 'Diff', 'Status']
        problematic_files.each do |result|
          t.add_row [
            result[:title].length > 30 ? result[:title][0..27] + '...' : result[:title],
            result[:content_type].to_s.capitalize,
            "#{result[:current_level].round(1)} LUFS",
            "#{result[:target_level].round(1)} LUFS",
            "#{result[:level_difference] > 0 ? '+' : ''}#{result[:level_difference].round(1)} dB",
            result[:adjustment_type]
          ]
        end
      end

      log table.to_s

      # Recommendations
      log "\n💡 RECOMMENDATIONS"
      too_loud = problematic_files.count { |r| r[:adjustment_type] == 'Too Loud' }
      too_quiet = problematic_files.count { |r| r[:adjustment_type] == 'Too Quiet' }

      log "Files too loud: #{too_loud} (will be reduced in volume)"
      log "Files too quiet: #{too_quiet} (will be increased in volume)"

      if needs_adjustment > 0
        log "\nTo normalize these files, run:"
        log "neutraliser process [PATH_TO_PLEX_LIBRARY] --profile #{@profile[:name]} --tolerance #{@tolerance}"
      end
    end

    def generate_csv_report(results)
      require 'csv'

      filename = "plex_audio_analysis_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv"

      CSV.open(filename, 'w') do |csv|
        csv << ['Title', 'File Path', 'Library Type', 'Content Type', 'Current Level (LUFS)',
                'Target Level (LUFS)', 'Level Difference (dB)', 'Needs Adjustment', 'Adjustment Type']

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
            result[:adjustment_type]
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
        results: results
      }

      filename = "plex_audio_analysis_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
      File.write(filename, JSON.pretty_generate(report_data))

      log "📊 JSON report saved to: #{filename}"
    end
  end
end
