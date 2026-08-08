# frozen_string_literal: true

# Shared helpers for the demo scripts (run.rb, ab.rb).

require 'open3'

module DemoSupport
  ROOT = File.expand_path('..', __dir__)

  TARGETS = {
    'reference' => -23.0,
    'livingroom' => -20.0,
    'night' => -16.0
  }.freeze

  # Chart palette. An explicit card background keeps the SVGs legible on both
  # light and dark GitHub themes, rather than depending on the page's colours.
  BG    = '#ffffff'
  INK   = '#1b1f24'
  MUTED = '#6a737d'
  RED   = '#d1495b'
  GREEN = '#2a9d8f'
  GRID  = '#e3e6ea'
  FONT  = '-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif'

  module_function

  def target_for(profile)
    TARGETS.fetch(profile) do
      abort "Unknown profile: #{profile}. Use one of: #{TARGETS.keys.join(', ')}"
    end
  end

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "Command failed: #{cmd.join(' ')}\n#{out}" unless status.success?

    out
  end

  def neutralise!(path, profile)
    run!('bundle', 'exec', File.join(ROOT, 'bin', 'neutraliser'),
         'process', '--replace', '--profile', profile, path)
  end

  # Integrated loudness via ebur128 — deliberately a *different* filter from the
  # loudnorm one neutraliser uses to decide, so the measurement isn't just
  # echoing back the tool's own numbers.
  def measure_lufs(path)
    out, = Open3.capture2e(
      'ffmpeg', '-hide_banner', '-nostats', '-i', path,
      '-map', 'a:0', '-af', 'ebur128=framelog=quiet', '-f', 'null', '-'
    )
    raise "Could not measure loudness of #{path}\n#{out}" unless out[/Integrated loudness:.*?I:\s*(-?\d+\.?\d*)\s*LUFS/m]

    Regexp.last_match(1).to_f
  end

  # Short-term (3s window) loudness over time, as [seconds, lufs] pairs.
  # This is what you actually perceive moment to moment, so it's the right
  # series for showing jumps between files in a sitting.
  def loudness_over_time(path)
    out, = Open3.capture2e(
      'ffmpeg', '-hide_banner', '-nostats', '-i', path, '-map', 'a:0',
      '-af', 'ebur128=metadata=1,ametadata=mode=print:key=lavfi.r128.S:file=-',
      '-f', 'null', '-'
    )
    series = []
    time = nil
    out.each_line do |line|
      if (m = line.match(/pts_time:(\d+\.?\d*)/))
        time = m[1].to_f
      elsif (m = line.match(/lavfi\.r128\.S=(-?\d+\.?\d*)/)) && time
        lufs = m[1].to_f
        # The filter emits -120 dB until its 3s window fills; that's silence
        # padding, not content.
        series << [time, lufs] if lufs > -70.0
      end
    end
    series
  end

  # Pink noise is broadband, so it behaves much more like film audio under
  # loudnorm than a pure tone would.
  def generate_clip(path, offset_lufs:, duration:, target: -20.0)
    run!(
      'ffmpeg', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', "testsrc2=size=320x240:rate=10:duration=#{duration}",
      '-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{duration}:amplitude=0.7",
      '-af', "volume=#{offset_lufs - target}dB",
      '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30',
      '-c:a', 'aac', '-b:a', '192k', '-shortest', '-y', path
    )
    path
  end

  def concat(paths, dest)
    list = "#{dest}.txt"
    File.write(list, paths.map { |p| "file '#{File.expand_path(p)}'" }.join("\n"))
    run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'concat',
         '-safe', '0', '-i', list, '-c', 'copy', '-y', dest)
    File.delete(list)
    dest
  end

  def svg_header(width, height, title, subtitle)
    [
      %(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" ) +
        %(viewBox="0 0 #{width} #{height}" font-family="#{FONT}">),
      %(<rect width="#{width}" height="#{height}" rx="8" fill="#{BG}"/>),
      %(<text x="32" y="34" font-size="17" font-weight="600" fill="#{INK}">#{title}</text>),
      %(<text x="32" y="54" font-size="12.5" fill="#{MUTED}">#{subtitle}</text>)
    ]
  end
end
