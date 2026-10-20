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
      raise FileManagerError, "Target file does not exist: #{target_path}" unless File.exist?(target_path)

      raise FileManagerError, "Source file does not exist: #{source_path}" unless File.exist?(source_path)

      begin
        # A rename replaces the directory entry, so the source file's mode
        # becomes the destination's mode. Preserve the original permissions
        # rather than accidentally making a private media file world-readable
        # according to the process umask.
        target_stat = File.stat(target_path)
        File.chmod(target_stat.mode & 0o7777, source_path)
        keep_owner(source_path, target_stat)
        File.rename(source_path, target_path)
      rescue Errno::EXDEV => e
        # source_path and target_path are on different filesystems - rename(2)
        # can't do this atomically, and silently falling back to copy+delete
        # (as FileUtils.mv would) means a crash mid-copy corrupts target_path
        # with nothing to recover from. Fail loudly instead of pretending.
        raise FileManagerError,
              'Atomic replacement failed: source and target are on different ' \
              "filesystems (#{e.message}) - refusing a non-atomic cross-filesystem replace"
      rescue StandardError => e
        raise FileManagerError, "Atomic replacement failed: #{e.message}"
      end
    end

    # The new file is created by whoever runs ffmpeg (root, in a container),
    # but the library's owner (Plex, the *arrs) must still be able to manage
    # it. Best effort: only a privileged process can hand a file to another user.
    def self.keep_owner(path, stat)
      File.chown(stat.uid, stat.gid, path)
    rescue Errno::EPERM, Errno::EINVAL
      nil
    end

    # Writes content to path without ever leaving a truncated/corrupt file
    # in place: write to a same-directory temp file, then rename it over
    # path (same single-rename atomicity as atomic_replace above).
    def self.atomic_write(path, content)
      temp_path = safe_temp_path(path)
      published = false
      mode = File.exist?(path) ? File.stat(path).mode & 0o7777 : 0o600
      File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(content)
      end
      File.rename(temp_path, path)
      published = true
    ensure
      FileUtils.rm_f(temp_path) if temp_path && !published
    end

    # Copies a potentially large file without exposing a partial destination.
    # The copy is completed beside the destination and published with one
    # rename, so ENOSPC, network errors, and interrupts leave any existing
    # destination untouched.
    def self.atomic_copy(source_path, destination_path)
      temp_path = safe_temp_path(destination_path)
      existing = File.stat(destination_path) if File.exist?(destination_path)
      mode = (existing || File.stat(source_path)).mode & 0o7777

      File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |destination|
        File.open(source_path, 'rb') do |source|
          IO.copy_stream(source, destination)
        end
      end
      keep_owner(temp_path, existing) if existing
      File.rename(temp_path, destination_path)
    ensure
      FileUtils.rm_f(temp_path) if temp_path
    end

    DURATION_TOLERANCE_S = 1.0

    # nil when the output is a faithful rewrite of the source (same duration
    # within a second, expected number of audio streams), else what is wrong.
    # ffmpeg can exit 0 on a short or stream-dropping write; a probe that merely
    # parses (verify_file_integrity) would pass that, and then the original goes.
    def self.output_mismatch(source_path, output_path, expected_audio_streams:)
      source_duration = FFmpegWrapper.probe_duration(source_path)
      output_duration = FFmpegWrapper.probe_duration(output_path)
      if source_duration && output_duration && (source_duration - output_duration).abs >= DURATION_TOLERANCE_S
        return "output is #{output_duration.round(1)}s long, source is #{source_duration.round(1)}s"
      end

      actual = FFmpegWrapper.detect_audio_tracks(output_path).count { |track| !track[:unknown] }
      return nil if actual == expected_audio_streams

      "output has #{actual} audio stream(s), expected #{expected_audio_streams}"
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
