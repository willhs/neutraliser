require 'open3'
require 'fileutils'
require 'securerandom'

module Neutraliser
  class FileManagerError < StandardError; end

  class FileManager
    def self.atomic_replace(source_path, target_path)
      backup_path = "#{target_path}.bak"

      unless File.exist?(target_path)
        raise FileManagerError, "Target file does not exist: #{target_path}"
      end

      unless File.exist?(source_path)
        raise FileManagerError, "Source file does not exist: #{source_path}"
      end

      # Create backup
      FileUtils.cp(target_path, backup_path)

      begin
        # Atomically replace target with source
        FileUtils.mv(source_path, target_path)
        # Success - remove backup
        FileUtils.rm(backup_path)
      rescue => e
        # Rollback on failure
        if File.exist?(backup_path)
          FileUtils.mv(backup_path, target_path)
        end
        raise FileManagerError, "Atomic replacement failed: #{e.message}"
      end
    end

    def self.safe_temp_path(original_path)
      dir = File.dirname(original_path)
      basename = File.basename(original_path, File.extname(original_path))
      ext = File.extname(original_path)

      # Use secure random to avoid collisions
      temp_name = "#{basename}_neutraliser_#{SecureRandom.hex(8)}#{ext}"
      File.join(dir, temp_name)
    end

    def self.cleanup_temp_files(pattern)
      # Clean up any leftover temporary files matching pattern
      Dir.glob(pattern).each do |file|
        begin
          if File.exist?(file) && file.include?('_neutraliser_')
            # Only delete files that are clearly our temp files and older than 1 hour
            if Time.now - File.mtime(file) > 3600
              FileUtils.rm(file)
            end
          end
        rescue => e
          # Don't fail cleanup if we can't delete a file
          Neutraliser.logger.log "  Warning: Could not clean up temp file #{file}: #{e.message}"
        end
      end
    end

    def self.verify_file_integrity(file_path)
      # Basic file integrity check
      return false unless File.exist?(file_path)
      return false if File.size(file_path) == 0

      # Try to probe the file with FFmpeg to verify it's valid
      begin
        stdout, stderr, status = Open3.capture3(
          'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
          '-of', 'default=nw=1:nk=1', file_path
        )
        status.success? && !stdout.strip.empty?
      rescue
        false
      end
    end
  end
end
