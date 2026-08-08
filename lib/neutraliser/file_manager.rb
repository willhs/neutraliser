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
    # A single rename(2) is atomic on POSIX filesystems: it either fully
    # succeeds (target_path now holds source_path's content) or fully fails
    # (target_path is left completely untouched) - there is no intermediate
    # state where target_path doesn't exist. That's a strictly stronger
    # guarantee than the old backup-then-swap approach (two renames, with a
    # window between them where target_path was briefly missing, and a
    # kill/crash in that window stranded the original at "#{target_path}.bak"
    # with no auto-recovery). Callers are expected to have already verified
    # source_path (see FileManager.verify_file_integrity) before calling
    # this, so no backup-for-rollback is needed here.
    def self.atomic_replace(source_path, target_path)
      unless File.exist?(target_path)
        raise FileManagerError, "Target file does not exist: #{target_path}"
      end

      unless File.exist?(source_path)
        raise FileManagerError, "Source file does not exist: #{source_path}"
      end

      begin
        File.rename(source_path, target_path)
      rescue Errno::EXDEV => e
        # source_path and target_path are on different filesystems - rename(2)
        # can't do this atomically, and silently falling back to copy+delete
        # (as FileUtils.mv would) means a crash mid-copy corrupts target_path
        # with nothing to recover from. Fail loudly instead of pretending.
        raise FileManagerError,
              "Atomic replacement failed: source and target are on different " \
              "filesystems (#{e.message}) - refusing a non-atomic cross-filesystem replace"
      rescue => e
        raise FileManagerError, "Atomic replacement failed: #{e.message}"
      end
    end

    # Writes content to path without ever leaving a truncated/corrupt file
    # in place: write to a same-directory temp file, then rename it over
    # path (same single-rename atomicity as atomic_replace above).
    def self.atomic_write(path, content)
      temp_path = safe_temp_path(path)
      File.write(temp_path, content)
      File.rename(temp_path, path)
    rescue => e
      FileUtils.rm_f(temp_path) if temp_path
      raise e
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
