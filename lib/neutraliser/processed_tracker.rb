require 'json'

module Neutraliser
  class ProcessedTracker
    FILENAME = '.neutraliser'.freeze

    def initialize(root_dir)
      @path = File.join(root_dir, FILENAME)
      @entries = load
    end

    def processed?(file_path, profile)
      key = tracker_key(file_path)
      entry = @entries[key]
      return false unless entry

      # Check file hasn't changed since we processed it
      return false unless File.exist?(file_path)
      return false if File.size(file_path) != entry['size']
      return false if File.mtime(file_path).to_i != entry['mtime']
      return false if entry['profile'] != profile[:name]

      true
    end

    def mark_processed(file_path, profile)
      key = tracker_key(file_path)
      @entries[key] = {
        'size' => File.size(file_path),
        'mtime' => File.mtime(file_path).to_i,
        'profile' => profile[:name],
        'processed_at' => Time.now.utc.iso8601
      }
      save
    end

    private

    def tracker_key(file_path)
      # Store relative path from the root dir so the tracker is portable
      root = File.dirname(@path)
      Pathname.new(File.expand_path(file_path)).relative_path_from(Pathname.new(root)).to_s
    end

    def load
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path))
    rescue JSON::ParserError
      {}
    end

    def save
      File.write(@path, JSON.pretty_generate(@entries))
    rescue StandardError => e
      Neutraliser.logger.log "  Warning: Could not write tracker file: #{e.message}"
    end
  end
end
