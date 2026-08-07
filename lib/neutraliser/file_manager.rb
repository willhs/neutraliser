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

      # Rename original to backup (instant, no extra disk space on same filesystem)
      FileUtils.mv(target_path, backup_path)

      begin
        # Move normalized file into place
        FileUtils.mv(source_path, target_path)
        # Success - remove backup
        FileUtils.rm(backup_path)
      rescue => e
        # Rollback on failure
        if File.exist?(backup_path)
          FileUtils.mv(backup_path, target_path)
        end
        FileUtils.rm_f(source_path)
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
