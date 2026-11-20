# frozen_string_literal: true

module Neutraliser
  # What encoder replaces a track in a given container, and at what bitrate (ADR-0001).
  # The one place that decides it: the codec-change guard and the real encode both read
  # `decide`, so they cannot disagree. Pure; the one thing that needs a probe, a bitrate
  # for a track ffprobe gave none for, comes in as `sample`.
  module CodecChoice
    # The decision for one track written into `container` (an extension such as '.mkv').
    # `sample` is called with the track, only when ffprobe gave no bit_rate and the
    # container's BPS tag is no help, and returns a bitrate in bps or nil.
    # `changes_codec` is true when the encoder is not the track's own codec: DTS/TrueHD
    # to FLAC or E-AC3 drops what the original was (a bitstream an AVR can decode, or
    # lossless turned lossy).
    #
    # `stamp` is the track's earlier NEUTRALISER_* record, if any. A lossy re-encode gets headroom
    # (HEADROOM) over the *first-generation* bitrate: the stamp's source_bitrate when it was a pass
    # over this same codec, else the file's own. A redo thus lands on the same rate instead of
    # growing 25% a pass. `first_generation_bitrate` is what the new stamp records.
    def self.decide(track, container, sample: nil, stamp: nil)
      source_codec = track[:codec]&.downcase || 'unknown'
      channels = track[:channels].to_i
      channels = 2 if channels.zero?
      allowed = CONTAINER_CODECS.fetch(container, CONTAINER_CODECS['.mkv'])
      encoder = resolve_encoder(source_codec, allowed, container, channels)
      return unencodable(track, source_codec, channels) unless encoder

      source_bitrate = known_bitrate(track, sample)
      first_generation = first_generation_bitrate(source_bitrate, source_codec, stamp)

      {
        encoder: encoder,
        encodable: true,
        bitrate: resolve_bitrate(encoder, first_generation, channels, headroom: ENCODABLE_CODECS[source_codec] == encoder),
        source_codec: source_codec,
        source_profile: track[:profile],
        source_bitrate: source_bitrate,
        first_generation_bitrate: first_generation,
        lossless_output: lossless_encoder?(encoder),
        changes_codec: ENCODABLE_CODECS[source_codec] != encoder
      }
    end

    # No encoder in this container takes this many channels (7.1 in an MP4: ffmpeg's AC-3 and E-AC-3
    # stop at 5.1 and FLAC is not allowed there). The track cannot be levelled in place, so the
    # decision has no encoder and the codec-change guard is not asked; `Guards#channel_count` stops
    # the file before it is measured.
    def self.unencodable(track, source_codec, channels)
      { encoder: nil, encodable: false, channels: channels, bitrate: nil, source_codec: source_codec,
        source_profile: track[:profile], source_bitrate: nil, first_generation_bitrate: nil,
        lossless_output: false, changes_codec: true }
    end

    def self.lossless_encoder?(encoder)
      encoder.start_with?('flac', 'pcm_')
    end

    # ffprobe's bit_rate, else the container's BPS tag (written by mkvmerge, already in the
    # track), else the sampler. 0 when none gives a usable number, so the quality floor applies.
    def self.known_bitrate(track, sample)
      reported = track[:bit_rate].to_i
      return reported if reported.positive?

      estimate = bitrate_from_tag(track) || sample&.call(track)
      estimate.to_i.positive? ? estimate : reported
    end

    def self.bitrate_from_tag(track)
      value = track.dig(:tags, 'BPS').to_s.strip
      return nil if value.empty? || value == 'N/A'

      value.to_i
    end

    def self.resolve_encoder(source_codec, allowed, container, channels)
      # 1. Try direct match — same codec if encodable and allowed in container
      direct = ENCODABLE_CODECS[source_codec]
      return direct if direct && allowed.include?(direct) && holds?(direct, channels)

      # 2. Lossless source — prefer lossless output if container supports it
      if LOSSLESS_CODECS.include?(source_codec)
        return 'flac' if allowed.include?('flac')
        return 'pcm_s24le' if allowed.include?('pcm_s24le')
        return 'pcm_s16le' if allowed.include?('pcm_s16le')
      end

      # 3. Beyond 5.1 (7.1, 6.1): only FLAC holds it, so there is no lossy fallback. nil when the
      #    container has no FLAC; ffmpeg's AC-3 / E-AC-3 stop at 5.1 and would fail every sweep.
      return (allowed.include?('flac') ? 'flac' : nil) if channels > 6

      # 3b. Non-encodable surround — prefer lossless if container supports it, else AC3/EAC3
      if channels >= 6
        return 'flac' if allowed.include?('flac')
        return 'eac3' if allowed.include?('eac3')
        return 'ac3' if allowed.include?('ac3')
      end

      # 4. Container default fallback
      fallback = CONTAINER_FALLBACKS.fetch(container, 'aac')
      return fallback if allowed.include?(fallback)

      # 5. Last resort — first allowed codec
      allowed.first || 'aac'
    end

    # The stamp's source_bitrate only when it describes this track's codec: after a codec change
    # (DTS -> E-AC-3) the stamp's codec and bitrate belong to the old stream.
    def self.first_generation_bitrate(source_bitrate, source_codec, stamp)
      stamped = stamp&.source_bitrate.to_i
      return source_bitrate unless stamped.positive? && stamp.source_codec.to_s.downcase == source_codec

      stamped
    end

    # `headroom` is false for a codec change (DTS to E-AC-3): that bitrate is not a re-encode of
    # the same codec, so it keeps the old rule.
    # False for an encoder that cannot take this many channels.
    def self.holds?(encoder, channels) = channels <= MAX_CHANNELS.fetch(encoder, channels)

    def self.resolve_bitrate(encoder, first_generation, channels, headroom:)
      return nil if lossless_encoder?(encoder)

      channel_key = [8, 6].find { |key| channels >= key } || 2
      floor = QUALITY_FLOORS.dig(encoder, channel_key) || QUALITY_FLOORS.dig(encoder, 2) || 128_000
      cap = QUALITY_CAPS.dig(encoder, channel_key) || QUALITY_CAPS.dig(encoder, 2) || 640_000

      return floor unless first_generation.positive?

      (headroom ? with_headroom(encoder, first_generation) : first_generation).clamp(floor, cap)
    end

    def self.with_headroom(encoder, bitrate)
      wanted = (bitrate * HEADROOM.fetch(encoder, 1)).ceil
      encoder == 'ac3' ? AC3_BITRATES.find { |step| step >= wanted } || AC3_BITRATES.last : wanted
    end
    private_class_method :known_bitrate, :resolve_encoder, :resolve_bitrate, :first_generation_bitrate, :with_headroom, :holds?, :unencodable
  end
end
