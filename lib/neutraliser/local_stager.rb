require 'fileutils'
require 'securerandom'

module Neutraliser
  class LocalStager
    STAGING_DIR = File.join(ENV['TMPDIR'] || '/tmp', 'neutraliser_staging').freeze

    def initialize(staging_dir: STAGING_DIR)
      @staging_dir = staging_dir
      FileUtils.mkdir_p(@staging_dir)
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
