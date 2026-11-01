# frozen_string_literal: true

# Plumbing for the review's experiments. Every run is the real CLI as a subprocess over a generated clip, and
# every judgement is read with something other than neutraliser's own measure where one exists: ebur128, ffmpeg's
# decoder honouring dialnorm, the raw bitstream.
#
# Core shape: Scenario (a clip plus CLI flags) -> Observed (what the output file really is). A claim is checked by
# comparing Observed against the source's Observed, never against what the tool logged.
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../../../..', __dir__)
require File.join(ROOT, 'lib/neutraliser')
require File.join(ROOT, 'spec/support/ac3_bits')

module Lab
  # What the NAS driver passes on every run (media-server's neutralise-driver.sh), minus its lock and disk floors.
  PROD = %w[--replace --tolerance 2 --min-gain 1 --no-fast-verify --no-cache].freeze
  NO_DRC = %w[-drc_scale 0].freeze

  module_function

  def tmp = (@tmp ||= Dir.mktmpdir('neutraliser-lab-'))
  at_exit { FileUtils.rm_rf(@tmp) if @tmp }

  def dir(name)
    path = File.join(tmp, "#{name}-#{SecureRandom.hex(3)}")
    FileUtils.mkdir_p(path)
    path
  end

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd.map(&:to_s))
    raise "#{cmd.first(12).join(' ')} failed:\n#{out.lines.last(12).join}" unless status.success?

    out
  end

  def ffmpeg(*args) = run!('ffmpeg', '-hide_banner', '-nostats', '-loglevel', 'error', '-y', *args)

  # LAB_IMAGE runs the CLI as the driver does, in the published image's Debian and its ffmpeg, with this tree's lib
  # mounted over the image's. Measuring stays on the host's ffmpeg, a second build reading what the first wrote.
  def cli(*args, bin: File.join(ROOT, 'bin/neutraliser'), lib: nil)
    image = ENV.fetch('LAB_IMAGE', nil)
    if image && bin == File.join(ROOT, 'bin/neutraliser')
      out, status = Open3.capture2e('docker', 'run', '--rm', '-v', "#{tmp}:#{tmp}", '-v', "#{dir('ctmp')}:/tmp", '-v', "#{ROOT}/lib:/app/lib:ro", image, *args.map(&:to_s))
    else
      env = lib ? { 'RUBYLIB' => lib } : {}
      out, status = Open3.capture2e(env, 'bundle', 'exec', 'ruby', bin, *args.map(&:to_s), chdir: ROOT)
    end
    [out, status.exitstatus]
  end

  def process(path, *flags) = cli('process', path, *PROD, *flags)

  def amp(db) = format('%.5f', 10**(db / 20.0))

  # Pink noise, quiet with a loud 4 s passage every 20 s: about 20 LU of range. Stereo.
  def programme_wav(path, seconds: 60, quiet_db: -34, loud_db: -14, layout: 'stereo')
    expr = "if(lt(mod(t\\,20)\\,4)\\,#{amp(loud_db)}\\,#{amp(quiet_db)})"
    ffmpeg('-f', 'lavfi', '-i', "anoisesrc=color=pink:sample_rate=48000:seed=7:duration=#{seconds}",
           '-af', "volume='#{expr}':eval=frame,aformat=channel_layouts=#{layout}", '-c:a', 'pcm_s24le', path)
    path
  end

  # The same noise on every channel of `layout`, so the channel count changes and little else.
  def surround_wav(path, layout, seconds: 30, db: -24)
    n = channels(layout)
    pan = (0...n).map { |c| "c#{c}=c0" }.join('|')
    ffmpeg('-f', 'lavfi', '-i', "anoisesrc=color=pink:sample_rate=48000:seed=9:duration=#{seconds}",
           '-af', "volume=#{db}dB,pan=#{layout}|#{pan}", '-c:a', 'pcm_s24le', path)
    path
  end

  def channels(layout)
    { 'mono' => 1, 'stereo' => 2, '2.1' => 3, '3.0' => 3, '3.0(back)' => 3, '4.0' => 4, 'quad' => 4, 'quad(side)' => 4,
      '3.1' => 4, '5.0' => 5, '5.0(side)' => 5, '4.1' => 5, '5.1' => 6, '5.1(side)' => 6, '6.0' => 6, '6.0(front)' => 6,
      'hexagonal' => 6, '6.1' => 7, '6.1(front)' => 7, '7.0' => 7, '7.0(front)' => 7, '7.1' => 8, '7.1(wide)' => 8 }.fetch(layout)
  end

  def encode(wav, out, codec:, dialnorm: nil, bitrate: '192k', extra: [])
    opts = dialnorm ? ['-dialnorm', dialnorm] : []
    ffmpeg('-i', wav, '-c:a', codec, '-b:a', bitrate, *opts, *extra, '-f', codec, out)
    out
  end

  # A stream or wav muxed with a tiny video track, stream copied, as its one default audio track.
  def mux(audio, out, extra: [])
    seconds = run!('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', audio).to_f
    ffmpeg('-f', 'lavfi', '-i', format('color=c=black:s=64x64:r=5:d=%.2f', seconds), '-i', audio,
           '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'copy', '-shortest', *extra, out)
    out
  end

  # AC-3 frames carrying a DRC word that pulls the loud passages down by about 8 dB, and none elsewhere.
  def ac3_with_drc(plain, out)
    File.binwrite(out, Ac3Bits.add_dynrng(File.binread(plain)) { |i| ((i * 1536 / 48_000.0) % 20) < 4 ? 0xD3 : 0 })
    out
  end

  # What ffmpeg's decoder gives, read with ebur128: I, LRA, true peak, sample peak.
  def levels(path, index: 0, decoder: NO_DRC, filter: nil)
    chain = [filter, 'ebur128=peak=sample+true'].compact.join(',')
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', *decoder, '-i', path, '-map', "0:a:#{index}",
                           '-af', chain, '-f', 'null', '-')
    summary = out[/Summary:.*\z/m] or raise "no ebur128 summary for #{path}\n#{out.lines.last(5).join}"
    { i: summary[/^\s+I:\s+(-?[\d.]+) LUFS/, 1].to_f, lra: summary[/^\s+LRA:\s+(-?[\d.]+) LU/, 1].to_f,
      sample_peak: summary[/Sample peak:\s+Peak:\s+(-?[\d.]+|-inf)/m, 1].to_f,
      true_peak: summary[/True peak:\s+Peak:\s+(-?[\d.]+|-inf)/m, 1].to_f }
  end

  def raw_stream(path, index, format)
    out = File.join(dir('raw'), "s.#{format}")
    ffmpeg('-i', path, '-map', "0:a:#{index}", '-c', 'copy', '-f', format, out)
    File.binread(out)
  end

  # dialnorm as the bitstream reader sees it.
  def bits_dialnorm(path, index: 0, codec: 'ac3') = Neutraliser::DolbyStream.dialnorm(raw_stream(path, index, codec))

  # dialnorm as a decoder that honours it applies it (ffmpeg's -target_level -31: gain of -31 - dialnorm), not the
  # tool's reader. The noise fixtures are steady, so this resolves to about a dB.
  def heard_dialnorm(path, index: 0)
    plain = levels(path, index: index)[:i]
    honoured = levels(path, index: index, decoder: [*NO_DRC, '-target_level', '-31'])[:i]
    (-31 - (honoured - plain)).round(1)
  end

  def stream_info(path, index: 0)
    out = run!('ffprobe', '-v', 'error', '-select_streams', "a:#{index}", '-show_entries',
               'stream=codec_name,profile,channels,channel_layout,sample_fmt,bits_per_raw_sample,bit_rate,sample_rate', '-of', 'json', path)
    JSON.parse(out).fetch('streams').first
  end

  def stamp(path) = Neutraliser::Source.new(path).stamp
  def sha(path) = Digest::SHA256.file(path).hexdigest[0, 12]

  def tree(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.to_h do |relative|
      path = File.join(root, relative)
      [relative, File.file?(path) ? [Digest::SHA256.file(path).hexdigest, File.mtime(path).to_f] : :dir]
    end
  end

  def table(title, headers, rows)
    widths = headers.each_index.map { |i| ([headers[i]] + rows.map { |row| row[i].to_s }).map(&:length).max }
    puts "\n## #{title}\n"
    puts headers.each_with_index.map { |h, i| h.to_s.ljust(widths[i]) }.join('  ')
    rows.each { |row| puts row.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join('  ') }
    $stdout.flush
  end

  def f1(value) = value.nil? ? '-' : format('%.1f', value)
end
