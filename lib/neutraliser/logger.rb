require 'fileutils'

module Neutraliser
  class Logger
    LOG_DIR = File.join(Dir.home, '.local', 'share', 'neutraliser', 'logs').freeze

    def initialize
      FileUtils.mkdir_p(LOG_DIR)
      @log_file = File.open(log_path, 'a')
      @log_file.sync = true
      @mutex = Mutex.new
    end

    def log(message)
      timestamped = "#{timestamp} #{message}"
      @mutex.synchronize do
        $stdout.puts timestamped
        @log_file.puts(timestamped)
      end
    end

    def log_path
      date = Time.now.strftime('%Y-%m-%d')
      File.join(LOG_DIR, "neutraliser-#{date}.log")
    end

    def close
      @log_file.close unless @log_file.closed?
    end

    private

    def timestamp
      Time.now.strftime('[%Y-%m-%d %H:%M:%S]')
    end
  end

  def self.logger
    @logger ||= Logger.new
  end
end
