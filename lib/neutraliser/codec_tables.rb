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
    LOSSLESS_CODECS = %w[flac pcm_s16le pcm_s16be pcm_s24le pcm_f32le truehd pcm_s32le].freeze

    # Minimum quality floor bitrates per encoder (in bps)
    QUALITY_FLOORS = {
      'aac' => { 2 => 128_000, 6 => 256_000 },
      'ac3' => { 2 => 192_000, 6 => 384_000 },
      'eac3' => { 2 => 128_000, 6 => 256_000 },
      'libmp3lame' => { 2 => 192_000 },
      'libtwolame' => { 2 => 192_000 },
      'libopus' => { 2 => 128_000, 6 => 256_000 },
      'libvorbis' => { 2 => 128_000, 6 => 256_000 }
    }.freeze

    # Maximum useful bitrates per encoder (in bps)
    QUALITY_CAPS = {
      'aac' => { 2 => 320_000, 6 => 512_000 },
      'ac3' => { 2 => 640_000, 6 => 640_000 },
      'eac3' => { 2 => 640_000, 6 => 1_536_000 },
      'libmp3lame' => { 2 => 320_000 },
      'libtwolame' => { 2 => 384_000 },
      'libopus' => { 2 => 256_000, 6 => 510_000 },
      'libvorbis' => { 2 => 256_000, 6 => 500_000 }
    }.freeze

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
