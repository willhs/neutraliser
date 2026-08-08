require 'fileutils'
require 'securerandom'
require_relative 'file_manager'

module Neutraliser
  class LocalStager
    STAGING_DIR = File.join(ENV['TMPDIR'] || '/tmp', 'neutraliser_staging').freeze

    def initialize(enabled:, staging_dir: STAGING_DIR)
      @enabled = enabled
      @staging_dir = staging_dir
      FileUtils.mkdir_p(@staging_dir) if @enabled
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
    # back via stage_out+cleanup; unstaged output is atomically replaced in
    # place, or - in copy mode - left where it already was written.
    def commit(output_path, destination, replace:)
      if @enabled
        stage_out(output_path, destination)
        cleanup(output_path)
      elsif replace
        FileManager.atomic_replace(output_path, destination)
      end
    end

    def stage_in(remote_path)
      ext = File.extname(remote_path)
      basename = File.basename(remote_path, ext)
      local_path = File.join(@staging_dir, "#{basename}_#{SecureRandom.hex(6)}#{ext}")

      Neutraliser.logger.log "  Staging in: #{remote_path} -> #{local_path}"
      FileUtils.cp(remote_path, local_path)
      local_path
    end

    def stage_out(local_path, remote_destination)
      Neutraliser.logger.log "  Staging out: #{local_path} -> #{remote_destination}"
      FileUtils.cp(local_path, remote_destination)
    end

    def cleanup(local_path)
      FileUtils.rm_f(local_path)
    end
  end
end
