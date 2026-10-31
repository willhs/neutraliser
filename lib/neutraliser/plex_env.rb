module Neutraliser
  # The two settings `analyze-plex` takes from a .env file. Read by hand, and
  # only for that command, because neutraliser is routinely started from inside
  # a media folder whose contents came from strangers: dotenv runs $(...) in
  # values and exports every key, so a .env in a download folder would run
  # commands and could set LD_PRELOAD or FFREPORT for ffmpeg.
  module PlexEnv
    KEYS = %w[PLEX_TOKEN PLEX_SERVER_URL].freeze
    LINE = /\A\s*(?:export\s+)?(#{KEYS.join('|')})\s*=\s*(.*?)\s*\z/

    # Variables already set in the environment win.
    def self.load(path = '.env')
      return unless File.file?(path)

      File.foreach(path) do |line|
        match = LINE.match(line.scrub)
        ENV[match[1]] ||= unquote(match[2]) if match
      end
    end

    def self.unquote(value)
      return value[1..-2] if value.match?(/\A(".*"|'.*')\z/)

      value.sub(/\s+#.*\z/, '')
    end
    private_class_method :unquote
  end
end
