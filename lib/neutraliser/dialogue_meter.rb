module Neutraliser
  # Reads a file's dialogue figures without changing it. The only method here is the one with no new
  # dependency: the centre channel of a surround mix, through the same EBU R 128 loudness measurement the
  # tool already uses. Film mixes keep speech there (EBU R 128 s4: a surround programme's speech "is
  # typically the Centre channel"), so its loudness stands in for the dialogue's. It reads high by as much as
  # effects or score in the channel outweigh the speech: -0.7 to +3.4 LU on the research's test mixes, +18.7 LU
  # with effects well over the speech there (docs/research/0003-sceptical-review-dolby-dialogue-compression).
  #
  # Stereo and mono have no centre to read: speech and background can't be told apart by channel, so they
  # get no figure rather than a bad one. A voice-activity gate would give them one (low confidence); that
  # add-on is decided in docs/design/adr/0003-optional-voice-gate-for-dialogue.md and not built yet.
  module DialogueMeter
    # Layouts of three or more channels that have no front centre. Others (5.1, 7.1, 5.0, 3.0, 4.0 ...) have it
    # at index 2, which is where `pan` reads it, so a stream with no layout name still works.
    NO_CENTRE_LAYOUT = /\A(2\.1|2\.2|quad|downmix|3\.0\(back\)|6\.0\(front\)|6\.1\(front\))/
    CENTRE_ONLY = 'pan=mono|c0=c2'.freeze

    module_function

    # track: a Source's primary_track. Raises FFmpegError if the read itself fails.
    def estimate(file, track)
      return DialogueEstimate.unavailable(no_centre_reason(track)) unless centre_channel?(track)

      measurement = FFmpegWrapper.measure_loudness(file, audio_index: track[:index], pre_filter: CENTRE_ONLY)
      return DialogueEstimate.unavailable('silent centre channel') if measurement.silent?

      DialogueEstimate.centre_channel(measurement.input_i)
    end

    # The dialnorm (dB) the file carries: a stamped file's is the source's, carried over by the re-encode
    # (a stamp without one means the source had none, and the encoder's -31 isn't a statement worth
    # reading back); an unstamped Dolby track says its own; anything else has none. Nil when unreadable.
    def dialnorm(file, track, stamp)
      return stamp.source_dialnorm if stamp
      return nil unless DolbyStream.dolby_codec?(track[:codec])

      FFmpegWrapper.read_dialnorm(file, track)
    rescue FFmpegError, SystemCallError => e
      Neutraliser.logger.log "  Could not read the dialnorm of #{file}: #{e.message.lines.first&.strip}"
      nil
    end

    def centre_channel?(track)
      track[:channels].to_i >= 3 && !track[:channel_layout].to_s.match?(NO_CENTRE_LAYOUT)
    end

    def no_centre_reason(track)
      case track[:channels].to_i
      when 1 then 'mono, no centre channel'
      when 2 then 'stereo, no centre channel'
      else "no centre channel in #{track[:channel_layout] || "#{track[:channels]} channels"}"
      end
    end
    private_class_method :centre_channel?, :no_centre_reason
  end
end
