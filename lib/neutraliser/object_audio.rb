module Neutraliser
  # Object-based audio (Dolby Atmos, DTS:X) detection. ffmpeg cannot encode
  # the object metadata, so re-encoding such a track silently flattens it to
  # plain channel audio — E-AC3 JOC to 5.1, TrueHD Atmos or DTS:X to FLAC.
  #
  # The primary signal is the stream `profile` ffprobe reports. libavcodec
  # (FFmpeg 7.1+) names these profiles, but its *decoder* sets them while
  # decoding a frame, not the demuxer — so the stream profile is only as good
  # as the frames ffprobe decoded while probing. When the file's name or the
  # track title says Atmos/DTS:X but the stream profile doesn't, a second
  # probe decodes a slice from mid-file before believing the profile. A name
  # alone never condemns a file. See docs/research/object-audio-detection.md.
  module ObjectAudio
    # libavcodec profile names: "Dolby Digital Plus + Dolby Atmos",
    # "Dolby TrueHD + Dolby Atmos", "DTS-HD MA + DTS:X", "DTS-HD MA + DTS:X IMAX".
    PROFILE_PATTERN = /atmos|dts:x/i
    # The only codecs that can carry object audio.
    CODECS = %w[eac3 truehd dts].freeze
    # Release-name / track-title spellings. Only ever triggers a deeper probe.
    NAME_HINT = /atmos|\bjoc\b|dts[:\-. ]?x(?![a-z0-9])/i

    # status is :object_audio (profile names the format), :suspected (the name
    # says so but neither probe confirms it) or :none.
    Verdict = Data.define(:status, :profile) do
      def object_audio? = status == :object_audio
    end

    NONE = Verdict.new(status: :none, profile: nil)

    def self.detect(input_path, track, name:)
      return Verdict.new(status: :object_audio, profile: track[:profile]) if object_profile?(track[:profile])
      return NONE unless CODECS.include?(track[:codec]) && hinted?(name, track[:title])

      deep_profile = FFmpegWrapper.probe_audio_profile_mid_file(input_path, track)
      return Verdict.new(status: :object_audio, profile: deep_profile) if object_profile?(deep_profile)

      Verdict.new(status: :suspected, profile: nil)
    end

    def self.object_profile?(profile)
      PROFILE_PATTERN.match?(profile.to_s)
    end

    def self.hinted?(*names)
      names.compact.any? { |n| NAME_HINT.match?(n) }
    end
  end
end
