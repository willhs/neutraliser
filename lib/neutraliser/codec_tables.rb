# frozen_string_literal: true

module Neutraliser
  # The codec, container and quality tables behind CodecChoice (ADR-0001), kept apart from its logic.
  module CodecChoice
    # Mapping from source codec to ffmpeg encoder name
    # Only codecs that ffmpeg can reliably encode
    ENCODABLE_CODECS = {
      'aac' => 'aac',
      'ac3' => 'ac3',
      'eac3' => 'eac3',
      'mp3' => 'libmp3lame',
      'mp2' => 'libtwolame',
      'opus' => 'libopus',
      'vorbis' => 'libvorbis',
      'flac' => 'flac',
      'pcm_s16le' => 'pcm_s16le',
      'pcm_s16be' => 'pcm_s16be',
      'pcm_s24le' => 'pcm_s24le',
      'pcm_f32le' => 'pcm_f32le'
    }.freeze

    # Codecs considered lossless
    LOSSLESS_CODECS = %w[flac pcm_s16le pcm_s16be pcm_s24le pcm_f32le truehd pcm_s32le pcm_s24be pcm_s32be pcm_f64le pcm_bluray].freeze

    # Minimum quality floor bitrates per encoder (in bps)
    QUALITY_FLOORS = {
      'aac' => { 2 => 128_000, 6 => 256_000, 8 => 320_000 },
      'ac3' => { 2 => 192_000, 6 => 384_000 },
      'eac3' => { 2 => 128_000, 6 => 256_000 },
      'libmp3lame' => { 2 => 192_000 },
      'libtwolame' => { 2 => 192_000 },
      'libopus' => { 2 => 128_000, 6 => 256_000, 8 => 320_000 },
      'libvorbis' => { 2 => 128_000, 6 => 256_000, 8 => 320_000 }
    }.freeze

    # Maximum useful bitrates per encoder (in bps). The 8 key (7.1) is above the 5.1 one: a 7.1 AAC
    # at 641k must not be pulled down to the 5.1 cap of 512k (it would land below its source).
    QUALITY_CAPS = {
      'aac' => { 2 => 320_000, 6 => 512_000, 8 => 768_000 },
      'ac3' => { 2 => 640_000, 6 => 640_000 },
      'eac3' => { 2 => 640_000, 6 => 1_536_000 },
      'libmp3lame' => { 2 => 320_000 },
      'libtwolame' => { 2 => 384_000 },
      'libopus' => { 2 => 256_000, 6 => 510_000, 8 => 680_000 },
      'libvorbis' => { 2 => 256_000, 6 => 500_000, 8 => 700_000 }
    }.freeze

    # Bitrate headroom (research 0004): the re-encode is one more lossy generation, and +25% bits on the
    # native encoders scored higher in all 16 source-window pairs measured. Only the encoders measured.
    # Applied to the first-generation bitrate, then held by the floors and caps above.
    HEADROOM = { 'aac' => Rational(5, 4), 'ac3' => Rational(5, 4), 'eac3' => Rational(5, 4) }.freeze

    # The only rates the AC-3 encoder takes (bps). ffmpeg 7.1 rounds 560k up to 576k itself; we do it
    # so older ffmpeg doesn't have to.
    AC3_BITRATES = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
                   .map { |kbps| kbps * 1000 }.freeze

    # Channels an encoder can write, where ffmpeg's is limited (FFmpeg's AC-3 and E-AC-3 stop at 5.1).
    # Any other encoder here is taken to hold what the source has.
    MAX_CHANNELS = { 'ac3' => 6, 'eac3' => 6 }.freeze

    # `--lossy71`: the lossy encoder an over-5.1 track goes to when its own codec can't be written
    # (E-AC-3 / AC-3 / DTS 7.1), instead of FLAC or a skip. Both hold eight channels in MP4 and MKV.
    LOSSY_71 = { 'aac' => 'aac', 'opus' => 'libopus' }.freeze

    # The over-5.1 layouts libopus maps (mapping family 1); a named one outside these, such as
    # 7.1(wide), fails to open the encoder. An unnamed layout is taken as the standard one.
    OPUS_WIDE_LAYOUTS = ['6.1', '7.1', '', 'unknown'].freeze

    # FLAC 7.1 of decoded lossy film audio against the E-AC-3 7.1 it came from (research 0007 finding 3;
    # an estimate, not measured on a real film). Said wherever a lossy 7.1 track is about to become FLAC.
    FLAC_71_COST = 'FLAC 7.1 is about 3-5x the size of the E-AC-3 (3-6 Mbit/s against 0.77-1.5), ' \
                   'and many TV clients cannot play multichannel FLAC'

    # Container compatibility — which encoders work in which containers
    CONTAINER_CODECS = {
      '.mp4' => %w[aac ac3 eac3 libmp3lame libopus],
      '.m4v' => %w[aac ac3 eac3 libmp3lame libopus],
      '.mov' => %w[aac ac3 eac3 libmp3lame pcm_s16le pcm_s24le],
      '.mkv' => %w[aac ac3 eac3 libmp3lame libtwolame libopus libvorbis flac pcm_s16le pcm_s24le pcm_f32le],
      '.webm' => %w[libopus libvorbis],
      '.avi' => %w[aac ac3 libmp3lame pcm_s16le],
      '.wmv' => %w[aac ac3 libmp3lame],
      '.flv' => %w[aac libmp3lame]
    }.freeze

    # Preferred fallback codec per container when source codec can't be matched
    CONTAINER_FALLBACKS = {
      '.mkv' => 'flac',
      '.mp4' => 'aac',
      '.m4v' => 'aac',
      '.mov' => 'aac',
      '.webm' => 'libopus',
      '.avi' => 'aac',
      '.wmv' => 'aac',
      '.flv' => 'aac'
    }.freeze
  end
end
