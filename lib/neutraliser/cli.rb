module Neutraliser
  class CLI < Thor
    desc 'process PATH', 'Process video file(s) at PATH'
    option :replace, type: :boolean, default: false, desc: 'Replace original files instead of creating copies'
    option :target_level, type: :numeric, default: -16.0, desc: 'Target LUFS level for normalisation'
    def process(path)
      processor = Processor.new(
        replace: options[:replace],
        target_level: options[:target_level]
      )

      processor.process(path)
    end

    desc 'analyze-plex', 'Analyze Plex library audio levels'
    option :server_url, type: :string, default: 'http://localhost:32400', desc: 'Plex server URL'
    option :token, type: :string, desc: 'Plex authentication token (overrides .env)'
    option :library, type: :string, desc: 'Specific library to analyze (default: all video libraries)'
    option :output_format, type: :string, default: 'table', desc: 'Report format: table, csv, json'
    option :sample_percent, type: :numeric, default: 100, desc: 'Analyze only N% of files for large libraries'
    option :concurrent_jobs, type: :numeric, default: 4, desc: 'Number of concurrent analysis jobs'
    option :cache_results, type: :boolean, default: false, desc: 'Cache analysis results to avoid re-analyzing'
    def analyze_plex
      analyzer = PlexAnalyzer.new(
        server_url: options[:server_url],
        token: options[:token],
        library_name: options[:library],
        output_format: options[:output_format],
        sample_percent: options[:sample_percent],
        concurrent_jobs: options[:concurrent_jobs],
        cache_results: options[:cache_results]
      )

      analyzer.analyze
    end

    desc 'version', 'Show version'
    def version
      puts "Neutraliser v#{VERSION}"
    end

    default_task :process
  end
end