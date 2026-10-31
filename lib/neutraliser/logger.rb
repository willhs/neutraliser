require 'fileutils'

module Neutraliser
  # Logs to stdout and, when it can, to a dated file. The file is best effort:
  # under `docker --user`, or with a read-only or full home, the run still has
  # to happen.
  class Logger
    def self.log_dir
      File.join(Dir.home, '.local', 'share', 'neutraliser', 'logs')
    end

    def initialize
      @log_file = open_log_file
      @mutex = Mutex.new
    end

    def log(message)
      timestamped = "#{timestamp} #{message}"
      @mutex.synchronize do
        $stdout.puts timestamped
        write_to_file(timestamped)
      end
    end

    def log_path
      date = Time.now.strftime('%Y-%m-%d')
      File.join(self.class.log_dir, "neutraliser-#{date}.log")
    end

    def close
      @log_file.close if @log_file && !@log_file.closed?
    end

    private

    def open_log_file
      FileUtils.mkdir_p(self.class.log_dir)
      File.open(log_path, 'a').tap { |file| file.sync = true }
    rescue SystemCallError, ArgumentError => e
      # ArgumentError: Dir.home with no HOME and no passwd entry for this uid.
      warn "Warning: not keeping a log file (#{e.message})"
      nil
    end

    def write_to_file(line)
      @log_file&.puts(line)
    rescue SystemCallError, IOError
      @log_file = nil
    end

    def timestamp
      Time.now.strftime('[%Y-%m-%d %H:%M:%S]')
    end
  end

  def self.logger
    @logger ||= Logger.new
  end
end
