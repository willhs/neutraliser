require 'fileutils'
require 'securerandom'

module Neutraliser
  class FileManagerError < StandardError; end

  # Raised specifically when a just-written output file fails its integrity
  # check — the one case where the original must not be replaced. Kept
  # distinct from FileManagerError (atomic-replace/temp-path failures) so
  # the Processor seam can rescue it and refuse to commit deliberately,
  # rather than lumping it in with a generic processing failure.
  class OutputVerificationError < StandardError; end

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

      # Probe via FFmpegWrapper so this runs through the same timeboxed
      # executor as every other subprocess call — this is checking a
      # freshly-written, possibly-truncated file, exactly the input most
      # likely to hang ffprobe indefinitely.
      begin
        !FFmpegWrapper.probe_duration(file_path).nil?
      rescue Errno::ENOENT => e
        # ffprobe isn't installed/on PATH — an environment problem, not a
        # verdict on this file's integrity. Distinguish it from "corrupt
        # output" (which returns false above) rather than conflating both
        # under one silent false.
        raise FileManagerError, "Cannot verify file integrity - ffprobe not found: #{e.message}"
      rescue FFmpegTimeoutError, FFmpegError
        # Probe ran but timed out or errored on this specific file - treat
        # as corrupt/unverifiable output rather than an environment problem.
        false
      end
    end
  end
end
