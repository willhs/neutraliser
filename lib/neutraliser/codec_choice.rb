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
    def self.decide(track, container, sample: nil)
      source_codec = track[:codec]&.downcase || 'unknown'
      channels = track[:channels].to_i
      channels = 2 if channels.zero?
      allowed = CONTAINER_CODECS.fetch(container, CONTAINER_CODECS['.mkv'])
      encoder = resolve_encoder(source_codec, allowed, container, channels)
      source_bitrate = known_bitrate(track, sample)

      {
        encoder: encoder,
        bitrate: resolve_bitrate(encoder, source_bitrate, channels),
        source_codec: source_codec,
        source_profile: track[:profile],
        source_bitrate: source_bitrate,
        lossless_output: lossless_encoder?(encoder),
        changes_codec: ENCODABLE_CODECS[source_codec] != encoder
      }
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
      return direct if direct && allowed.include?(direct)

      # 2. Lossless source — prefer lossless output if container supports it
      if LOSSLESS_CODECS.include?(source_codec)
        return 'flac' if allowed.include?('flac')
        return 'pcm_s24le' if allowed.include?('pcm_s24le')
        return 'pcm_s16le' if allowed.include?('pcm_s16le')
      end

      # 3. Non-encodable surround — prefer lossless if container supports it, else AC3/EAC3
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

    def self.resolve_bitrate(encoder, source_bitrate, channels)
      return nil if lossless_encoder?(encoder)

      channel_key = channels >= 6 ? 6 : 2
      floor = QUALITY_FLOORS.dig(encoder, channel_key) || QUALITY_FLOORS.dig(encoder, 2) || 128_000
      cap = QUALITY_CAPS.dig(encoder, channel_key) || QUALITY_CAPS.dig(encoder, 2) || 640_000

      source_bitrate.positive? ? source_bitrate.clamp(floor, cap) : floor
    end
    private_class_method :known_bitrate, :resolve_encoder, :resolve_bitrate
  end
end
