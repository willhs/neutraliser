module Neutraliser
  # Which audio stream of the output is which. The one place that knows the
  # output's audio order: every source track keeps its position, the primary
  # track (the default-disposition one, else the first) is replaced in place by
  # its normalised version, and with --keep-original-audio an untouched copy of
  # the primary follows it, so every later track moves up by one.
  #
  # RemuxPlan builds the ffmpeg command from a layout; verification compares the
  # written file with the same layout, so neither re-derives who is where.
  class AudioLayout
    # role: :normalised (the primary, re-encoded), :kept_original (a stream copy of
    # the primary, after it) or :copied (any other track, stream-copied).
    # source_index: the track's position among the source's audio streams.
    # dispositions: the flags to give the stream (an empty list clears them), nil to
    # leave what a stream copy carries over.
    Output = Data.define(:index, :role, :source_index, :dispositions)

    ORIGINAL_TITLE_SUFFIX = '(original, not normalised)'.freeze

    # A track a previous --keep-original-audio run preserved. Found by title (or the
    # handler name MP4 shows instead), because MP4 drops custom stream tags.
    def self.original_copy?(track)
      [track[:title], track[:handler_name]].any? { |name| name.to_s.end_with?(ORIGINAL_TITLE_SUFFIX) }
    end

    def self.original_title(track)
      [track[:title], ORIGINAL_TITLE_SUFFIX].compact.reject(&:empty?).join(' ')
    end

    # A file that already carries a kept original from an earlier run is not given a second copy.
    def self.for(source, keep_original:)
      tracks = source.audio_tracks
      primary = source.primary_track
      keep = keep_original && tracks.none? { |track| original_copy?(track) }
      outputs = []
      tracks.each do |track|
        if track.equal?(primary)
          outputs << output(outputs, :normalised, track, normalised_dispositions(track, keep))
          outputs << output(outputs, :kept_original, track, []) if keep
        else
          outputs << output(outputs, :copied, track, nil)
        end
      end
      new(outputs)
    end

    # A filtered stream carries no disposition of its own, so every flag the source
    # track had (hearing_impaired, forced ...) has to be given back. With a kept
    # original the normalised track is the one players should pick.
    def self.normalised_dispositions(primary, keep)
      flags = Array(primary[:dispositions])
      flags = ['default', *flags] if keep || primary[:default]
      flags.any? ? flags : nil
    end

    def self.output(outputs, role, track, dispositions)
      Output.new(index: outputs.length, role: role, source_index: track[:index], dispositions: dispositions)
    end
    private_class_method :normalised_dispositions, :output

    attr_reader :outputs

    def initialize(outputs)
      @outputs = outputs.freeze
    end

    # How many audio streams the output should have.
    def size = outputs.length

    # nil when the source has no audio.
    def normalised = outputs.find { |o| o.role == :normalised }

    def kept_original = outputs.find { |o| o.role == :kept_original }
  end
end
