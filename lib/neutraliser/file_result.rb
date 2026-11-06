module Neutraliser
  # What one run did with one file: done (re-levelled, or would be on a dry run),
  # skipped (left as it is, on purpose) or failed. Every result names its reason from
  # the closed list below, so the run summary, the run manifest and --resume all read
  # the same symbols and a misspelt reason raises where it is made, not in a count.
  #
  # mode is how the level was changed (Mode), set on a real re-encode. left is the
  # LeftRecord to persist for a file skipped but not done (see Processor#record_outcome).
  #
  # The reasons reach the run manifest as strings (`reason.to_s`), and --resume reads
  # manifests written by older versions, so none of these may be renamed or dropped.
  FileResult = Data.define(:file, :status, :reason, :message, :mode, :left)

  # (The class body: the closed lists of statuses and reasons, and the ways to make one.)
  class FileResult
    REASONS = {
      done: %i[normalized dry_run],
      skipped: %i[already_processed unsupported_format no_audio_track low_disk silent peak_limited
                  within_tolerance object_audio codec_change],
      failed: %i[unreadable not_writable unsupported_subtitle timeout output_verification_failed
                 source_changed ffmpeg_error file_manager_error processing_error invalid_result]
    }.freeze

    # The only outcomes --resume takes as the last word on a file. Every other one
    # depends on something that can change between runs (a flag, free space, the
    # ffmpeg version, or a dry run that did nothing) and goes back through
    # SkipDecider, which costs one probe.
    FINAL_REASONS = %i[normalized already_processed no_audio_track unsupported_format].freeze

    # An exception out of a file's processing, in the order they are tried: the
    # reason it becomes (nil: the error names its own) and how the log says it.
    ERRORS = [
      # Retryable: the subprocess ran out of time, not evidence the file (or the
      # output already committed) is bad.
      [FFmpegTimeoutError, :timeout, 'Timed out processing file'],
      # The one case where the original must not be replaced: surfaced distinctly
      # so the manifest doesn't read as "same as any other failure" when the real
      # story is "output looked corrupt, original is untouched".
      [OutputVerificationError, :output_verification_failed, 'Output verification failed'],
      [SourceChangedError, :source_changed, 'Source changed'],
      # Non-retryable ffmpeg/ffprobe failure (bad container, unsupported codec,
      # failed probe), distinct from a timeout so "try again" and "this file is
      # broken" don't mix. The error names the kinds it can recognise
      # (:not_writable, :unsupported_subtitle); the rest are :ffmpeg_error.
      [FFmpegError, nil, 'FFmpeg error processing file'],
      [FileManagerError, :file_manager_error, 'File management error processing file'],
      [StandardError, :processing_error, 'Error processing file']
    ].freeze

    def initialize(file:, status:, reason:, message: nil, mode: nil, left: nil)
      known = REASONS.fetch(status) { raise ArgumentError, "unknown status #{status.inspect}" }
      raise ArgumentError, "#{reason.inspect} is not a reason for a #{status} file" unless known.include?(reason)

      super(file: File.expand_path(file), status: status, reason: reason, message: message, mode: mode, left: left)
    end

    def self.done(file, reason, mode: nil) = new(file: file, status: :done, reason: reason, mode: mode)

    def self.skipped(file, reason, message: nil, left: nil)
      new(file: file, status: :skipped, reason: reason, message: message, left: left)
    end

    def self.failed(file, reason, message: nil) = new(file: file, status: :failed, reason: reason, message: message)

    def self.from_error(file, error)
      _, reason, = ERRORS.find { |klass, _, _| error.is_a?(klass) }
      failed(file, reason || error.reason, message: error.message)
    end

    def self.error_label(error) = ERRORS.find { |klass, _, _| error.is_a?(klass) }.last

    # A manifest holds reasons as strings; --resume asks whether one is a given reason,
    # or one it takes as final.
    def self.reason?(text, reason) = text == reason.to_s
    def self.final_reason?(text) = FINAL_REASONS.any? { |reason| reason?(text, reason) }

    def done? = status == :done
    def skipped? = status == :skipped
    def failed? = status == :failed
  end
end
