module Neutraliser
  class PlexAnalyzer
    # Audio level targets based on content type (LUFS)
    TARGET_LEVELS = {
      movie: -27.0,    # Netflix standard for theatrical content
      tv: -23.0,       # Broadcast television standard
      other: -14.0     # General streaming content standard
    }.freeze

    ACCEPTABLE_VARIANCE = 3.0 # LUFS variance considered acceptable

    attr_reader :server_url, :token, :library_name, :output_format,
                :sample_percent, :concurrent_jobs, :cache_results

    def initialize(server_url:, token: nil, library_name: nil, output_format: 'table',
                   sample_percent: 100, concurrent_jobs: 4, cache_results: false)
      @server_url = server_url
      @token = token
      @library_name = library_name
      @output_format = output_format
      @sample_percent = sample_percent
      @concurrent_jobs = concurrent_jobs
      @cache_results = cache_results
      @plex_server = nil
    end

    def analyze
      puts "🎵 Starting Plex library audio analysis..."

      connect_to_plex
      libraries = discover_video_libraries

      if libraries.empty?
        puts "❌ No video libraries found on Plex server"
        return
      end

      results = analyze_libraries(libraries)
      generate_report(results)
    rescue => e
      puts "❌ Analysis failed: #{e.message}"
      puts "💡 Make sure your Plex server is running and accessible at #{resolve_server_url}"
      exit 1
    end

    private

    def connect_to_plex
      @server_url = resolve_server_url
      puts "🔌 Connecting to Plex server at #{@server_url}..."

      @auth_token = resolve_token
      unless @auth_token
        puts "❌ No Plex token found!"
        puts "💡 Create a .env file with: PLEX_TOKEN=your_token_here"
        puts "💡 Or get your token from: #{@server_url}/web/index.html#!/settings/account"
        exit 1
      end

      # Test connection with direct HTTP request
      puts "🔍 Testing connection..."
      begin
        response = make_plex_request('/library/sections')

        if response.code == '200'
          sections_data = JSON.parse(response.body)
          section_count = sections_data.dig('MediaContainer', 'size') || 0
          puts "✅ Connected to Plex server successfully"
          puts "📚 Found #{section_count} library sections"
          @connected = true
        else
          puts "❌ Connection failed: HTTP #{response.code} - #{response.message}"
          exit 1
        end
      rescue => e
        puts "❌ Connection test failed: #{e.message}"
        puts "💡 Debug info: #{e.class}"
        raise e
      end
    end

    def make_plex_request(path)
      uri = URI.parse(@server_url + path)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')

      request = Net::HTTP::Get.new(uri)
      request['X-Plex-Token'] = @auth_token
      request['Accept'] = 'application/json'

      response = http.request(request)
      response
    end

    def resolve_server_url
      # Priority: CLI option > .env file > default
      return server_url if server_url != 'http://localhost:32400'

      env_url = ENV['PLEX_SERVER_URL']
      if env_url && !env_url.strip.empty?
        puts "🌐 Using server URL from .env file"
        return env_url.strip
      end

      server_url
    end

    def resolve_token
      # Priority: explicit token parameter > .env file
      return token if token

      # Try .env file
      env_token = ENV['PLEX_TOKEN']
      if env_token && !env_token.strip.empty?
        puts "🔑 Using token from .env file"
        return env_token.strip
      end

      nil
    end

    def discover_video_libraries
      puts "📚 Discovering video libraries..."

      response = make_plex_request('/library/sections')
      unless response.code == '200'
        puts "❌ Failed to get libraries: HTTP #{response.code}"
        exit 1
      end

      data = JSON.parse(response.body)
      all_libraries = data.dig('MediaContainer', 'Directory') || []

      # Filter to video libraries (movie and show types)
      video_libraries = all_libraries.select { |lib| lib['type'] == 'movie' || lib['type'] == 'show' }

      if library_name
        selected_library = video_libraries.find { |lib| lib['title'].downcase == library_name.downcase }
        if selected_library
          video_libraries = [selected_library]
          puts "🎯 Analyzing specific library: #{selected_library['title']}"
        else
          puts "⚠️  Library '#{library_name}' not found. Available libraries:"
          video_libraries.each { |lib| puts "   - #{lib['title']} (#{lib['type']})" }
          exit 1
        end
      else
        puts "📋 Found #{video_libraries.length} video libraries:"
        video_libraries.each { |lib| puts "   - #{lib['title']} (#{lib['type']})" }
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
      puts "\n🔍 Analyzing library: #{library['title']}"

      # Get all media items from the library using Plex API
      response = make_plex_request("/library/sections/#{library['key']}/all")
      unless response.code == '200'
        puts "❌ Failed to get library contents: HTTP #{response.code}"
        return []
      end

      data = JSON.parse(response.body)
      all_items = data.dig('MediaContainer', 'Metadata') || []

      # Apply sampling if requested
      if sample_percent < 100
        sample_size = (all_items.size * sample_percent / 100.0).ceil
        all_items = all_items.sample(sample_size)
        puts "📊 Sampling #{sample_size} items (#{sample_percent}% of #{all_items.size} total)"
      end

      puts "🎬 Found #{all_items.size} items to analyze"

      results = []
      processed = 0

      all_items.each do |item|
        begin
          result = analyze_media_item(item, library['type'])
          results << result if result
          processed += 1

          # Progress indicator
          if processed % 10 == 0
            puts "   ⏳ Processed #{processed}/#{all_items.size} items..."
          end
        rescue => e
          puts "   ❌ Error analyzing #{item['title']}: #{e.message}"
        end
      end

      puts "✅ Completed analysis of #{library['title']}: #{results.size} valid results"
      results
    end

    def analyze_media_item(item, library_type)
      title = item['title'] || 'Unknown Title'

      # Get Plex streaming URL
      streaming_url = get_plex_streaming_url(item)
      unless streaming_url
        puts "   🚫 #{title}: No streaming URL available"
        return nil
      end

      puts "   📡 #{title}: Analyzing via Plex stream..."

      # Determine content type for target level selection
      content_type = determine_content_type(item, library_type)
      target_level = TARGET_LEVELS[content_type]

      begin
        # Analyze audio level from streaming URL
        current_level = analyze_streaming_audio(streaming_url)

        # Skip if we can't get a valid measurement
        if current_level == -20.0 || current_level == -18.0  # Skip placeholder/fallback values
          puts "   ⚠️  #{title}: Got placeholder audio level (#{current_level}), skipping"
          return nil
        end

        puts "   ✅ #{title}: Audio level #{current_level} LUFS"

        {
          title: title,
          file_path: streaming_url,
          library_type: library_type,
          content_type: content_type,
          current_level: current_level,
          target_level: target_level,
          level_difference: current_level - target_level,
          needs_adjustment: needs_adjustment?(current_level, target_level),
          adjustment_type: get_adjustment_type(current_level, target_level)
        }
      rescue => e
        puts "   ❌ #{title}: Error analyzing audio - #{e.message}"
        return nil
      end
    end

    def get_plex_streaming_url(item)
      # Get the media part key for streaming
      media_array = item['Media']
      return nil unless media_array && media_array.is_a?(Array) && media_array.first

      parts_array = media_array.first['Part']
      return nil unless parts_array && parts_array.is_a?(Array) && parts_array.first

      part_key = parts_array.first['key']
      return nil unless part_key

      # Construct Plex streaming URL
      "#{@server_url}#{part_key}?X-Plex-Token=#{@auth_token}"
    end

    def analyze_streaming_audio(streaming_url)
      # Use ffmpeg to analyze audio from streaming URL
      temp_analysis_file = "/tmp/plex_loudness_analysis_#{Time.now.to_i}.txt"

      begin
        # Run ffmpeg loudnorm filter with HTTP input
        cmd = [
          'ffmpeg', '-hide_banner', '-nostats',
          '-i', streaming_url,
          '-t', '60', # Analyze first 60 seconds for speed
          '-af', 'loudnorm=I=-16:dual_mono=true:TP=-1.5:LRA=11:print_format=summary',
          '-f', 'null', '-',
          '2>', temp_analysis_file
        ].join(' ')

        system(cmd)

        if File.exist?(temp_analysis_file)
          analysis_output = File.read(temp_analysis_file)

          # Parse the integrated loudness from ffmpeg output
          if match = analysis_output.match(/Input Integrated:\s*([-\d.]+)\s*LUFS/)
            integrated_loudness = match[1].to_f
            return integrated_loudness
          end
        end

        # Fallback
        -18.0
      rescue => e
        puts "    Warning: Stream analysis failed (#{e.message}), using fallback"
        -18.0
      ensure
        File.delete(temp_analysis_file) if File.exist?(temp_analysis_file)
      end
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

    def needs_adjustment?(current_level, target_level)
      (current_level - target_level).abs > ACCEPTABLE_VARIANCE
    end

    def get_adjustment_type(current_level, target_level)
      diff = current_level - target_level
      if diff.abs <= ACCEPTABLE_VARIANCE
        'OK'
      elsif diff > 0
        'Too Loud'
      else
        'Too Quiet'
      end
    end

    def generate_report(results)
      puts "\n" + "="*80
      puts "🎵 PLEX LIBRARY AUDIO ANALYSIS REPORT"
      puts "="*80

      if results.empty?
        puts "❌ No valid audio analysis results found"
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
        puts "❌ Unknown output format: #{output_format}"
        generate_table_report(results)
      end
    end

    def generate_table_report(results)
      # Summary statistics
      total_files = results.size
      needs_adjustment = results.count { |r| r[:needs_adjustment] }
      by_type = results.group_by { |r| r[:content_type] }

      puts "\n📊 SUMMARY STATISTICS"
      puts "Total files analyzed: #{total_files}"
      puts "Files needing adjustment: #{needs_adjustment} (#{(needs_adjustment.to_f / total_files * 100).round(1)}%)"
      puts "Files within target range: #{total_files - needs_adjustment} (#{((total_files - needs_adjustment).to_f / total_files * 100).round(1)}%)"

      puts "\n📋 BY CONTENT TYPE"
      by_type.each do |type, items|
        needs_adj = items.count { |r| r[:needs_adjustment] }
        puts "#{type.to_s.capitalize}: #{items.size} files, #{needs_adj} need adjustment"
      end

      # Detailed results table
      puts "\n🎬 DETAILED RESULTS (files needing adjustment)"
      problematic_files = results.select { |r| r[:needs_adjustment] }

      if problematic_files.empty?
        puts "🎉 All files are within acceptable volume ranges!"
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

      puts table

      # Recommendations
      puts "\n💡 RECOMMENDATIONS"
      too_loud = problematic_files.count { |r| r[:adjustment_type] == 'Too Loud' }
      too_quiet = problematic_files.count { |r| r[:adjustment_type] == 'Too Quiet' }

      puts "Files too loud: #{too_loud} (will be reduced in volume)"
      puts "Files too quiet: #{too_quiet} (will be increased in volume)"

      if needs_adjustment > 0
        puts "\nTo normalize these files, run:"
        puts "neutraliser process [PATH_TO_PLEX_LIBRARY] --target_level [APPROPRIATE_TARGET]"
        puts "\nConsider processing by content type for best results:"
        by_type.each do |type, items|
          target = TARGET_LEVELS[type]
          puts "#{type.to_s.capitalize} content: --target_level #{target}"
        end
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

      puts "📊 CSV report saved to: #{filename}"
    end

    def generate_json_report(results)
      require 'json'

      report_data = {
        analysis_date: Time.now.iso8601,
        server_url: server_url,
        total_files: results.size,
        files_needing_adjustment: results.count { |r| r[:needs_adjustment] },
        target_levels: TARGET_LEVELS,
        acceptable_variance: ACCEPTABLE_VARIANCE,
        results: results
      }

      filename = "plex_audio_analysis_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
      File.write(filename, JSON.pretty_generate(report_data))

      puts "📊 JSON report saved to: #{filename}"
    end
  end
end