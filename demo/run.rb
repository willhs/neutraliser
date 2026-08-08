#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates the before/after loudness chart in the README.
#
#   ruby demo/run.rb                     # synthetic clips, spread across a realistic range
#   ruby demo/run.rb --source ~/movies   # your own files (copies them first; originals untouched)
#
# Measures each file's integrated loudness with ffmpeg's ebur128 filter, runs
# neutraliser over a scratch copy, measures again, and writes an SVG slope
# chart plus a text table. Nothing outside --work-dir is modified.

require 'fileutils'
require 'optparse'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)

options = {
  source: nil,
  work_dir: File.join(Dir.tmpdir, 'neutraliser-demo'),
  profile: 'livingroom',
  duration: 20,
  limit: 8,
  output: File.join(ROOT, 'demo', 'loudness-before-after.svg')
}

OptionParser.new do |o|
  o.banner = 'Usage: ruby demo/run.rb [options]'
  o.on('--source DIR', 'Use video files from DIR instead of synthetic clips') { |v| options[:source] = v }
  o.on('--work-dir DIR', 'Scratch directory (default: a temp dir)') { |v| options[:work_dir] = v }
  o.on('--profile NAME', 'Profile to normalise against (default: livingroom)') { |v| options[:profile] = v }
  o.on('--duration SECS', Integer, 'Synthetic clip length (default: 20)') { |v| options[:duration] = v }
  o.on('--limit N', Integer, 'Max files to use from --source (default: 8)') { |v| options[:limit] = v }
  o.on('--output PATH', 'Where to write the SVG') { |v| options[:output] = v }
  o.on('-h', '--help') { puts o; exit }
end.parse!

TARGETS = {
  'reference' => -23.0,
  'livingroom' => -20.0,
  'night' => -16.0
}.freeze

target = TARGETS.fetch(options[:profile]) do
  abort "Unknown profile: #{options[:profile]}. Use one of: #{TARGETS.keys.join(', ')}"
end

# Loudness levels chosen to look like a real mixed library: a couple of very
# quiet films, a cluster near broadcast standard, and a loud remaster.
SYNTHETIC_OFFSETS = [-31.5, -27.0, -24.5, -21.0, -19.5, -17.0, -14.5, -12.0].freeze

def run!(*cmd)
  out, status = Open3.capture2e(*cmd)
  raise "Command failed: #{cmd.join(' ')}\n#{out}" unless status.success?

  out
end

# Integrated loudness via ebur128 — deliberately a *different* filter from the
# loudnorm one neutraliser uses to decide, so the measurement isn't just
# echoing back the tool's own numbers.
def measure_lufs(path)
  out, = Open3.capture2e(
    'ffmpeg', '-hide_banner', '-nostats', '-i', path,
    '-map', 'a:0', '-af', 'ebur128=framelog=quiet', '-f', 'null', '-'
  )
  match = out[/Integrated loudness:.*?I:\s*(-?\d+\.?\d*)\s*LUFS/m]
  raise "Could not measure loudness of #{path}\n#{out}" unless match

  Regexp.last_match(1).to_f
end

def generate_clips(dir, duration)
  SYNTHETIC_OFFSETS.each_with_index.map do |offset, i|
    path = File.join(dir, format('clip_%02d.mkv', i + 1))
    # Pink noise is broadband, so it behaves much more like film audio under
    # loudnorm than a pure tone would.
    run!(
      'ffmpeg', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', "testsrc2=size=320x240:rate=10:duration=#{duration}",
      '-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{duration}:amplitude=0.7",
      '-af', "volume=#{offset + 20.0}dB",
      '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30',
      '-c:a', 'aac', '-b:a', '192k', '-shortest', '-y', path
    )
    path
  end
end

def collect_sources(source_dir, work_dir, limit)
  exts = %w[.mkv .mp4 .m4v .avi .mov]
  files = Dir.glob(File.join(source_dir, '**', '*'))
             .select { |f| File.file?(f) && exts.include?(File.extname(f).downcase) }
             .sort
             .first(limit)
  abort "No video files found under #{source_dir}" if files.empty?

  files.map do |src|
    dest = File.join(work_dir, File.basename(src))
    FileUtils.cp(src, dest)
    dest
  end
end

def svg(rows, target, profile)
  width  = 760
  height = 440
  pad_top = 108
  pad_bottom = 62
  plot_h = height - pad_top - pad_bottom
  x_before = 230
  x_after  = 540

  all = rows.flat_map { |r| [r[:before], r[:after]] } + [target]
  lo = [all.min - 1.5, -34.0].min
  hi = [all.max + 1.5, -10.0].max
  y = ->(lufs) { pad_top + plot_h - ((lufs - lo) / (hi - lo) * plot_h) }

  # An explicit card background keeps this legible on both light and dark
  # GitHub themes, rather than depending on the page's own colours.
  bg     = '#ffffff'
  ink    = '#1b1f24'
  muted  = '#6a737d'
  before = '#d1495b'
  after  = '#2a9d8f'
  grid   = '#e3e6ea'

  parts = []
  parts << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">)
  parts << %(<rect width="#{width}" height="#{height}" rx="8" fill="#{bg}"/>)
  parts << %(<text x="32" y="34" font-size="17" font-weight="600" fill="#{ink}">Integrated loudness, before and after</text>)
  parts << %(<text x="32" y="54" font-size="12.5" fill="#{muted}">#{rows.size} files &#183; neutraliser --profile #{profile} &#183; measured with ffmpeg ebur128</text>)

  # Target line
  ty = y.call(target).round(1)
  parts << %(<line x1="170" y1="#{ty}" x2="#{width - 32}" y2="#{ty}" stroke="#{grid}" stroke-width="1.5" stroke-dasharray="5 4"/>)
  parts << %(<text x="#{width - 32}" y="#{ty - 30}" font-size="11.5" fill="#{muted}" text-anchor="end">target #{format('%.1f', target)} LUFS</text>)

  # Column headers
  parts << %(<text x="#{x_before}" y="#{pad_top - 26}" font-size="12.5" font-weight="600" fill="#{before}" text-anchor="middle">BEFORE</text>)
  parts << %(<text x="#{x_after}" y="#{pad_top - 26}" font-size="12.5" font-weight="600" fill="#{after}" text-anchor="middle">AFTER</text>)

  rows.each do |r|
    yb = y.call(r[:before]).round(1)
    ya = y.call(r[:after]).round(1)
    parts << %(<line x1="#{x_before}" y1="#{yb}" x2="#{x_after}" y2="#{ya}" stroke="#{muted}" stroke-width="1.1" opacity="0.45"/>)
    parts << %(<circle cx="#{x_before}" cy="#{yb}" r="5" fill="#{before}"/>)
    parts << %(<circle cx="#{x_after}" cy="#{ya}" r="5" fill="#{after}"/>)
    parts << %(<text x="#{x_before - 14}" y="#{yb + 4}" font-size="11.5" fill="#{ink}" text-anchor="end">#{format('%.1f', r[:before])}</text>)
  end

  # The "after" values land on top of each other — that IS the result, so
  # label the cluster once rather than stacking eight identical numbers.
  afters = rows.map { |r| r[:after] }
  cluster_y = ((y.call(afters.max) + y.call(afters.min)) / 2).round(1)
  worst = afters.map { |a| (a - target).abs }.max
  label = if worst < 0.05
            format('all at %.1f LUFS', target)
          else
            format('all within %.1f LU of target', worst)
          end
  parts << %(<text x="#{x_after + 20}" y="#{cluster_y + 4}" font-size="12" font-weight="600" fill="#{after}">#{label}</text>)

  spread_before = (rows.map { |r| r[:before] }.max - rows.map { |r| r[:before] }.min)
  spread_after  = (rows.map { |r| r[:after] }.max - rows.map { |r| r[:after] }.min)
  parts << %(<text x="32" y="#{height - 20}" font-size="12.5" fill="#{ink}">Spread across the set: <tspan fill="#{before}" font-weight="600">#{format('%.1f', spread_before)} LU</tspan> &#8594; <tspan fill="#{after}" font-weight="600">#{format('%.1f', spread_after)} LU</tspan></text>)
  parts << '</svg>'
  parts.join("\n")
end

# --- Run ---

work = options[:work_dir]
FileUtils.rm_rf(work)
FileUtils.mkdir_p(work)

puts "Work dir: #{work}"

files =
  if options[:source]
    puts "Copying up to #{options[:limit]} files from #{options[:source]} (originals untouched)..."
    collect_sources(options[:source], work, options[:limit])
  else
    puts "Generating #{SYNTHETIC_OFFSETS.size} synthetic clips (#{options[:duration]}s each)..."
    generate_clips(work, options[:duration])
  end

puts 'Measuring before...'
before = files.to_h { |f| [f, measure_lufs(f)] }

puts "Normalising (--profile #{options[:profile]} --replace)..."
neutraliser = File.join(ROOT, 'bin', 'neutraliser')
run!('bundle', 'exec', neutraliser, 'process', '--replace', '--profile', options[:profile], work)

puts 'Measuring after...'
rows = files.map do |f|
  { name: File.basename(f), before: before[f], after: measure_lufs(f) }
end.sort_by { |r| r[:before] }

puts
puts format('%-28s %10s %10s', 'file', 'before', 'after')
rows.each { |r| puts format('%-28s %9.1f %9.1f', r[:name][0, 28], r[:before], r[:after]) }
puts
spread = ->(k) { rows.map { |r| r[k] }.max - rows.map { |r| r[k] }.min }
puts format('spread: %.1f LU -> %.1f LU', spread.call(:before), spread.call(:after))

FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], svg(rows, target, options[:profile]))
puts "Wrote #{options[:output]}"
