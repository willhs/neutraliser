require 'json'

module Neutraliser
  # What ffprobe says about one file, asked once. Everything the run wants to know
  # about a file before or after it is written (its audio tracks, which one is
  # primary, stream and chapter counts, duration, container, cover art, the
  # NEUTRALISER_* stamp, subtitles ffmpeg can't copy) comes from one
  # `ffprobe -show_streams -show_format -show_chapters` run, made the first time
  # any of it is asked for and kept for the life of the object. Hand the object
  # to whoever needs a fact rather than the path, so no fact costs a second probe.
  #
  # A Source describes the file as it was probed. The output a run writes gets its
  # own Source after writing: verification must not trust the source's numbers.
  #
  # Unreadable: a probe that fails raises FFmpegError (FFmpegTimeoutError for a hang)
  # from the first fact asked, and again from every later one: the answer is kept,
  # so a bad file costs one probe too. `readable?` asks without raising for a failure;
  # `stamp` is the one best-effort fact, because it only ever argues for skipping.
  class Source
    # Disposition flags a filtered stream loses and has to be given back. Named,
    # not copied from ffprobe, because ffprobe also reports flags that older
    # ffmpegs refuse on the command line. `default` is handled on its own.
    PRESERVED_DISPOSITIONS = %w[dub original comment lyrics karaoke forced hearing_impaired visual_impaired
                                clean_effects captions descriptions].freeze

    # What `primary_track` answers for a file ffprobe read but showed no audio in.
    # `unknown: true` lets a caller tell "we don't know this file's audio format"
    # from a real stereo track. Run code checks `audio?` first, so nothing
    # encodes against it.
    UNKNOWN_AUDIO_TRACK = { index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil,
                            unknown: true }.freeze

    # Everything one probe yields. Immutable, so a staged copy of the file can share it.
    Facts = Data.define(:audio_tracks, :stream_counts, :duration, :format_name, :container_tags,
                        :attached_picture, :unsupported_subtitles)

    attr_reader :path

    # Probes lazily: no subprocess until a fact is asked for.
    def initialize(path, facts: nil)
      @path = path
      @facts = facts
    end

    # A Source from ffprobe's own output (JSON text, and the stderr of a `-v info` run, which names
    # subtitle codec ids ffmpeg has no decoder for). The real probe goes through here too.
    def self.from_ffprobe(path, json_text, stderr = '')
      new(path, facts: parse(json_text, stderr))
    end

    # The same facts about a copy of the file (a local-staged working copy): same bytes, so no second probe.
    def for_copy(copy_path)
      self.class.new(copy_path, facts: facts)
    end

    # Did ffprobe read the file? A hang is not an answer, so it still raises.
    def readable?
      facts
      true
    rescue FFmpegTimeoutError
      raise
    rescue FFmpegError
      false
    end

    # The audio streams ffprobe found, in file order. `index` is the position among audio streams
    # (what `0:a:N` maps take), not the container's stream number.
    def audio_tracks = facts.audio_tracks

    def audio? = audio_tracks.any?

    # The track that gets measured and normalised: the one flagged default, else the first English
    # one, else the first. Players pick the default track, so that is the one whose level the viewer
    # hears; with no flag, multi-language releases (Spanish first, English second) are heard in
    # English, not in whichever stream happens to come first. UNKNOWN_AUDIO_TRACK when there is no audio.
    def primary_track
      @primary_track ||= audio_tracks.find { |t| t[:default] } || audio_tracks.find { |t| t[:language] == 'eng' } ||
                         audio_tracks.first || UNKNOWN_AUDIO_TRACK
    end

    # { video:, audio:, subtitle:, attachment:, chapter: }
    def stream_counts = facts.stream_counts

    # Seconds, or nil when the container reports none (a truncated file).
    def duration = facts.duration

    # True when the bytes are MP4-family whatever the name says (a release can be MP4 named .mkv).
    def mp4_family? = facts.format_name.to_s.include?('mp4')

    def attached_picture? = facts.attached_picture

    # Lower-cased names of the container-level tags.
    def container_tag_names = facts.container_tags.keys.map(&:downcase)

    # "stream N (CODEC_ID)" for each subtitle stream this ffmpeg has no codec for.
    def unsupported_subtitles = facts.unsupported_subtitles

    # The NEUTRALISER_* record a previous run left. The primary audio stream's tags win; container
    # tags are the fallback, because MP4 only keeps custom tags at container level. nil when there is
    # none or the file can't be probed (a miss just means "not known to be processed").
    def stamp
      Stamp.from_tags(primary_track[:tags]) || Stamp.from_tags(facts.container_tags)
    rescue FFmpegError, SystemCallError
      nil
    end

    def self.parse(json_text, stderr)
      data = JSON.parse(json_text)
      streams = Array(data['streams'])
      Facts.new(
        audio_tracks: audio_tracks_of(streams),
        stream_counts: stream_counts_of(streams, data['chapters']),
        duration: positive(data.dig('format', 'duration')),
        format_name: data.dig('format', 'format_name'),
        container_tags: data.dig('format', 'tags') || {},
        attached_picture: streams.any? { |stream| stream.dig('disposition', 'attached_pic') == 1 },
        unsupported_subtitles: unsupported_subtitles_of(streams, stderr)
      )
    rescue JSON::ParserError => e
      raise FFmpegError.new("ffprobe output could not be read (#{e.message.lines.first&.strip})", stderr: stderr)
    end

    def self.audio_tracks_of(streams)
      streams.select { |stream| stream['codec_type'] == 'audio' }.each_with_index.map do |stream, idx|
        {
          index: idx,
          stream_index: stream['index'].to_i,
          channels: stream['channels'].to_i,
          channel_layout: stream['channel_layout'],
          codec: stream['codec_name'] || 'unknown',
          profile: profile_name(stream['profile']),
          title: stream.dig('tags', 'title'),
          handler_name: stream.dig('tags', 'handler_name'),
          language: stream.dig('tags', 'language')&.downcase,
          default: stream.dig('disposition', 'default') == 1,
          dispositions: PRESERVED_DISPOSITIONS.select { |flag| stream.dig('disposition', flag) == 1 },
          bit_rate: bit_rate(stream['bit_rate']),
          sample_rate: stream['sample_rate']&.to_i,
          tags: stream['tags'] || {}
        }
      end
    end

    def self.stream_counts_of(streams, chapters)
      kinds = streams.map { |stream| stream['codec_type'] }.tally
      {
        video: kinds.fetch('video', 0), audio: kinds.fetch('audio', 0), subtitle: kinds.fetch('subtitle', 0),
        attachment: kinds.fetch('attachment', 0), chapter: Array(chapters).length
      }
    end

    # A subtitle stream no decoder names has no codec_name; the demuxer logs its codec id at info level,
    # in stream order.
    def self.unsupported_subtitles_of(streams, stderr)
      codec_ids = stderr.to_s.scan(%r{Unknown/unsupported AVCodecID (\S+?)\.?$}).flatten
      unknown = streams.select { |stream| stream['codec_type'] == 'subtitle' && !stream['codec_name'] }
      unknown.each_with_index.map { |stream, i| "stream #{stream['index']} (#{codec_ids[i] || 'unknown codec'})" }
    end

    # ffprobe prints "unknown" when the decoder named no profile.
    def self.profile_name(value)
      value.nil? || value.empty? || value == 'unknown' ? nil : value
    end

    def self.bit_rate(value)
      value.nil? || value == 'N/A' ? nil : value.to_i
    end

    def self.positive(value)
      number = value.to_f
      number.positive? ? number : nil
    end
    private_class_method :audio_tracks_of, :stream_counts_of, :unsupported_subtitles_of, :bit_rate, :positive

    private

    def facts
      return @facts if @facts
      raise @error if @error

      stdout, stderr = FFmpegWrapper.probe_file(path)
      @facts = self.class.parse(stdout, stderr)
    rescue FFmpegError => e
      @error = e
      raise
    end
  end
end
