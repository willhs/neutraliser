require 'open3'

module Neutraliser
  # Free-space floors for the volume a run writes to, so a long sweep over a
  # NAS never fills it (the 2026-07 disk crisis took Plex and the *arrs down
  # with it). Two floors, both off by default:
  #   min_free   - below this (or below the file's own size) a file is skipped
  #                and the run carries on;
  #   abort_free - below this the whole run stops.
  # Replacing a file renames the new one over the old, so the transient need is
  # one extra copy of the file, not two.
  class DiskGuard
    class Abort < StandardError; end

    GIB = 1024**3

    def initialize(min_free: nil, abort_free: nil)
      @min_free = min_free
      @abort_free = abort_free
    end

    def enabled? = !(@min_free.nil? && @abort_free.nil?)

    # :ok, :skip (too little room for this file) or :abort (too little room for anything).
    def verdict(dir, file_size)
      return :ok unless enabled?

      free = free_bytes(dir)
      return :ok unless free

      return :abort if @abort_free && free < @abort_free
      return :skip if @min_free && free < [@min_free, file_size].max

      :ok
    end

    def free_bytes(dir)
      out, status = Open3.capture2('df', '-Pk', dir)
      return nil unless status.success?

      kb = out.lines[1].to_s.split[3]
      kb && kb.to_i * 1024
    rescue SystemCallError
      nil
    end
  end
end
