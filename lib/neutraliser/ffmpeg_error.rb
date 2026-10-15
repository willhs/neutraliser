module Neutraliser
  # An ffmpeg/ffprobe run that exited non-zero. The message is one line —
  # what failed plus the last stderr line that says why — so it fits a
  # manifest entry and can be counted. The full stderr (banner, stream
  # listing and all) stays on #stderr for anyone debugging.
  #
  # #reason is the failure kind the run summary groups by. Most failures are
  # :ffmpeg_error; the ones we can name get their own reason so a library
  # run's failures sort into "fix the folder permissions" and "this file's
  # subtitles can't be copied" rather than one undifferentiated pile.
  class FFmpegError < StandardError
    MAX_DETAIL_LENGTH = 300

    # ffmpeg's chatter: banner, build config, stream listing, progress and
    # the generic trailer that follows every real error.
    NOISE = [
      /\Affmpeg version /, /\Affprobe version /, /\Abuilt with /, /\Aconfiguration: /, /\Alib\w+\s+\d/,
      /\AInput #/, /\AOutput #/, /\AStream #/, /\AStream mapping:/, /\AMetadata:/, /\AChapters?/,
      /\ADuration: /, /\A\S+\s+: /, /\Aframe=/, /\Asize=/, /\APress \[q\]/, /\AConsider increasing/,
      /\AConversion failed!\z/
    ].freeze

    ERRORISH = /error|fail|invalid|denied|not supported|unsupported|could not|cannot|unable|no such/i

    # Ordered: first match wins. Matched against the whole stderr, since the
    # line naming the cause is often not the last one (a subtitle failure
    # ends "Could not write header", with "Subtitle codec 0 is not
    # supported" a line above).
    REASONS = [
      [:not_writable, /Error opening output files?: Permission denied/i],
      [:unsupported_subtitle, Regexp.union(/Subtitle codec \S+ is not supported/,
                                           %r{Unknown/unsupported AVCodecID S_},
                                           /\(Subtitle: none\)/)]
    ].freeze

    attr_reader :stderr, :reason

    def initialize(message = nil, stderr: nil, reason: nil)
      super(message)
      @stderr = stderr
      @reason = reason || :ffmpeg_error
    end

    # "Normalization failed (exit 1): Error opening output files: Permission denied"
    def self.from_run(operation, stderr, status)
      exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : 'unknown'
      new("#{operation} failed (exit #{exit_status}): #{last_meaningful_line(stderr)}",
          stderr: stderr, reason: classify(stderr))
    end

    def self.classify(stderr)
      REASONS.find { |_, pattern| stderr.to_s.match?(pattern) }&.first || :ffmpeg_error
    end

    # The last line that names an error, else the last line that isn't
    # chatter. Log prefixes keep the component ("[matroska]") but lose the
    # pointer address, which differs every run.
    def self.last_meaningful_line(stderr)
      lines = stderr.to_s.each_line.map { |line| line.strip.gsub(/ @ 0x\h+\]/, ']') }
      lines.reject! { |line| line.empty? || NOISE.any? { |pattern| line.match?(pattern) } }
      line = lines.reverse.find { |l| l.match?(ERRORISH) } || lines.last
      return 'no error output' unless line

      line.length > MAX_DETAIL_LENGTH ? "#{line[0, MAX_DETAIL_LENGTH]}..." : line
    end
  end

  # The subprocess ran out of time: retryable, not evidence the file is bad.
  class FFmpegTimeoutError < FFmpegError
    def initialize(message = nil, **)
      super(message, reason: :timeout)
    end
  end
end
