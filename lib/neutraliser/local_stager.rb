require 'fileutils'
require 'securerandom'
require_relative 'file_manager'

module Neutraliser
  class LocalStager
    STAGING_DIR = File.join(ENV['TMPDIR'] || '/tmp', 'neutraliser_staging').freeze

    def initialize(enabled:, staging_dir: STAGING_DIR)
      @enabled = enabled
      @staging_dir = staging_dir
      prepare_staging_dir if @enabled
    end

    # Stages `file_path` in (or passes it through untouched when staging is
    # off), yields the working path, and guarantees cleanup of any staged
    # copy in an ensure - regardless of how the block exits (normal return,
    # early return, or exception). If staging itself fails, working_path
    # never diverges from file_path, so cleanup is correctly skipped.
    def with_working_copy(file_path)
      working_path = file_path
      working_path = stage_in(file_path) if @enabled
      yield working_path
    ensure
      cleanup(working_path) if @enabled && working_path != file_path
    end

    # Owns the replace x staging commit matrix: staged output always goes
    # back via stage_out+cleanup; unstaged output is renamed from its temp name
    # over the original, or onto the copy's own name, once it has been verified.
    def commit(output_path, destination, replace:)
      if @enabled
        stage_out(output_path, destination)
        cleanup(output_path)
      elsif replace
        FileManager.atomic_replace(output_path, destination)
      else
        FileManager.publish(output_path, destination)
      end
    end

    def stage_in(remote_path)
      ext = File.extname(remote_path)
      basename = File.basename(remote_path, ext)
      local_path = File.join(@staging_dir, "#{basename}_#{SecureRandom.hex(6)}#{ext}")

      copied = false
      Neutraliser.logger.log "  Staging in: #{remote_path} -> #{local_path}"
      FileUtils.cp(remote_path, local_path)
      copied = true
      local_path
    ensure
      FileUtils.rm_f(local_path) if local_path && !copied
    end

    def stage_out(local_path, remote_destination)
      Neutraliser.logger.log "  Staging out: #{local_path} -> #{remote_destination}"
      FileManager.atomic_copy(local_path, remote_destination)
    end

    def cleanup(local_path)
      FileUtils.rm_f(local_path)
    end

    private

    # The default lives under a shared /tmp on Linux. Whoever controls this
    # directory can swap the working copy, and we'd then publish their file
    # over the original.
    def prepare_staging_dir
      FileUtils.mkdir_p(@staging_dir, mode: 0o700)
      raise FileManagerError, "staging directory #{@staging_dir} is not owned by this user" unless File.owned?(@staging_dir)

      File.chmod(0o700, @staging_dir)
    end
  end
end
