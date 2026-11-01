# frozen_string_literal: true

require 'open3'
require 'json'
require_relative 'ac3_bits'

# Clips with Dolby loudness metadata the real CLI can be run over, for the DRC and dialnorm
# regression specs. FFmpeg's AC-3 encoder writes a dialnorm of your choosing (-dialnorm) but
# never a dynamic-range (DRC) word, so a fixture that has DRC needs the bits edited in by
# hand: Ac3Bits.add_dynrng.
module DolbyFixture
  FRAME_SECONDS = 1536 / 48_000.0
  LOUD_EVERY = 20
  LOUD_LEN = 4
  # dynrng 0xD3 is about -8 dB (X = -2, Y = 0b10011: 2^-2 * (1 + 19/32) = 0.398)
  LOUD_DYNRNG = 0xD3

  module_function

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd.map(&:to_s))
    raise "#{cmd.join(' ')} failed:\n#{out.lines.last(15).join}" unless status.success?

    out
  end

  def ffmpeg(*) = run!('ffmpeg', '-hide_banner', '-nostats', '-loglevel', 'error', '-y', *)

  # 60 s of stereo pink noise, quiet with a loud 4 s passage every 20 s: a stand-in for a mix with
  # a loudness range (about 20 LU).
  def programme(path, gain_db: 0, seconds: 60, quiet_db: -34, loud_db: -14)
    amp = ->(db) { format('%.5f', 10**((db + gain_db) / 20.0)) }
    expr = "if(lt(mod(t\\,#{LOUD_EVERY})\\,#{LOUD_LEN})\\,#{amp.call(loud_db)}\\,#{amp.call(quiet_db)})"
    ffmpeg('-f', 'lavfi', '-i', "anoisesrc=color=pink:sample_rate=48000:seed=7:duration=#{seconds}",
           '-af', "volume='#{expr}':eval=frame,aformat=channel_layouts=stereo", '-c:a', 'pcm_s16le', path)
    path
  end

  # A raw AC-3 or E-AC-3 stream of the wav, with the given dialnorm in every frame.
  def encode(wav, out, codec:, dialnorm:, options: [])
    ffmpeg('-i', wav, '-c:a', codec, '-b:a', '192k', '-dialnorm', dialnorm, *options, '-f', codec, out)
    File.binread(out)
  end

  # Matroska with a tiny video stream (neutraliser only takes video files) and the stream as
  # its one, default, audio track, stream-copied.
  def mkv(stream_path, out)
    seconds = run!('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', stream_path).to_f
    ffmpeg('-f', 'lavfi', '-i', format('color=c=black:s=64x64:r=5:d=%.2f', seconds), '-i', stream_path,
           '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'copy', '-shortest', out)
    out
  end

  # The first audio stream as a raw stream, bytes.
  def raw_stream(path, format)
    out = "#{path}.out.#{format}"
    ffmpeg('-i', path, '-map', '0:a:0', '-c:a', 'copy', '-f', format, out)
    File.binread(out)
  end

  # Integrated loudness and LRA of the first audio stream, as ffmpeg decodes it with `decoder_args`
  # (`-drc_scale 0` for the signal without DRC, `-target_level -31` for a decoder that honours dialnorm).
  def measure(path, *decoder_args)
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', *decoder_args.map(&:to_s), '-i', path, '-map', '0:a:0',
                           '-af', 'ebur128', '-f', 'null', '-')
    summary = out[/Summary:.*\z/m] or raise "no ebur128 summary for #{path}\n#{out}"
    { i: summary[/^\s+I:\s+(-?[\d.]+) LUFS/, 1].to_f, lra: summary[/^\s+LRA:\s+(-?[\d.]+) LU/, 1].to_f }
  end

  def stamp_tags(path)
    out = run!('ffprobe', '-v', 'error', '-show_entries', 'stream_tags:format_tags', '-of', 'json', path)
    JSON.parse(out).fetch('streams', []).each_with_object({}) do |stream, tags|
      (stream['tags'] || {}).each { |key, value| tags[key.upcase] = value if key.upcase.start_with?('NEUTRALISER') }
    end
  end
end
