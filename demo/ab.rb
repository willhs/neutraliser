#!/usr/bin/env ruby
# frozen_string_literal: true

# The A/B test: what four files back to back actually sound like, before and
# after. Builds two playlists from the same source clips — one untouched, one
# normalised — and plots perceived (short-term) loudness across each.
#
#   ruby demo/ab.rb
#   ruby demo/ab.rb --source ~/media/movies   # your own files
#
# Also writes before.mkv / after.mkv into the work dir so you can listen to the
# difference rather than just look at it.

require 'fileutils'
require 'optparse'
require 'tmpdir'
require_relative 'support'

options = {
  source: nil,
  work_dir: File.join(Dir.tmpdir, 'neutraliser-ab'),
  profile: 'livingroom',
  duration: 15,
  output: File.join(DemoSupport::ROOT, 'demo', 'loudness-over-time.svg')
}

OptionParser.new do |o|
  o.banner = 'Usage: ruby demo/ab.rb [options]'
  o.on('--source DIR', 'Use video files from DIR instead of synthetic clips') { |v| options[:source] = v }
  o.on('--work-dir DIR', 'Scratch directory') { |v| options[:work_dir] = v }
  o.on('--profile NAME', 'Profile to normalise against (default: livingroom)') { |v| options[:profile] = v }
  o.on('--duration SECS', Integer, 'Synthetic clip length (default: 15)') { |v| options[:duration] = v }
  o.on('--output PATH', 'Where to write the SVG') { |v| options[:output] = v }
  o.on('-h', '--help') do
    puts o
    exit
  end
end.parse!

target = DemoSupport.target_for(options[:profile])

# Deliberately jarring running order: a quiet film, then a loud one, then a
# quiet one again — the sequence that has people reaching for the remote.
PLAYLIST = [
  { label: 'quiet film', offset: -29.0 },
  { label: 'loud remaster', offset: -13.5 },
  { label: 'quiet doco',   offset: -25.5 },
  { label: 'TV episode',   offset: -17.5 }
].freeze

def svg(before_series, after_series, boundaries, target, profile, labels)
  width  = 860
  height = 400
  pad_l  = 62
  pad_r  = 24
  pad_top = 96
  pad_bottom = 58
  plot_w = width - pad_l - pad_r
  plot_h = height - pad_top - pad_bottom

  duration = [before_series.last[0], after_series.last[0]].max
  lo = -34.0
  hi = -8.0
  x = ->(t) { pad_l + (t / duration * plot_w) }
  y = ->(l) { pad_top + plot_h - ((l.clamp(lo, hi) - lo) / (hi - lo) * plot_h) }

  parts = DemoSupport.svg_header(
    width, height,
    'Four files back to back: perceived loudness over time',
    "short-term (3s) loudness &#183; neutraliser --profile #{profile} &#183; measured with ffmpeg ebur128"
  )

  parts << %(<text x="#{pad_l - 10}" y="#{pad_top - 12}" font-size="11" fill="#{DemoSupport::MUTED}" text-anchor="end">LUFS</text>)

  # Y gridlines
  [-10, -15, -20, -25, -30].each do |lufs|
    gy = y.call(lufs).round(1)
    parts << %(<line x1="#{pad_l}" y1="#{gy}" x2="#{width - pad_r}" y2="#{gy}" stroke="#{DemoSupport::GRID}" stroke-width="1"/>)
    parts << %(<text x="#{pad_l - 10}" y="#{gy + 4}" font-size="11" fill="#{DemoSupport::MUTED}" text-anchor="end">#{lufs}</text>)
  end

  # File boundaries
  boundaries.each_with_index do |t, i|
    bx = x.call(t).round(1)
    parts << %(<line x1="#{bx}" y1="#{pad_top}" x2="#{bx}" y2="#{pad_top + plot_h}" stroke="#{DemoSupport::GRID}" stroke-width="1" stroke-dasharray="3 3"/>)
    next unless labels[i]

    mid = ((t + (boundaries[i + 1] || duration)) / 2.0)
    # Clamp so the first and last labels don't run off the card.
    half = labels[i].length * 3.1
    lx = x.call(mid).clamp(pad_l + half, width - pad_r - half).round(1)
    parts << %(<text x="#{lx}" y="#{pad_top + plot_h + 20}" font-size="11" fill="#{DemoSupport::MUTED}" text-anchor="middle">#{labels[i]}</text>)
  end

  # Target line
  ty = y.call(target).round(1)
  parts << %(<line x1="#{pad_l}" y1="#{ty}" x2="#{width - pad_r}" y2="#{ty}" stroke="#{DemoSupport::GREEN}" stroke-width="1" stroke-dasharray="5 4" opacity="0.5"/>)

  path = lambda do |series|
    series.map.with_index { |(t, l), i| "#{i.zero? ? 'M' : 'L'}#{x.call(t).round(1)},#{y.call(l).round(1)}" }.join(' ')
  end

  parts << %(<path d="#{path.call(before_series)}" fill="none" stroke="#{DemoSupport::RED}" stroke-width="1.8" stroke-linejoin="round"/>)
  parts << %(<path d="#{path.call(after_series)}" fill="none" stroke="#{DemoSupport::GREEN}" stroke-width="1.8" stroke-linejoin="round"/>)

  # Legend
  parts << %(<circle cx="#{pad_l + 6}" cy="#{pad_top - 26}" r="5" fill="#{DemoSupport::RED}"/>)
  parts << %(<text x="#{pad_l + 18}" y="#{pad_top - 22}" font-size="12.5" fill="#{DemoSupport::INK}">before</text>)
  parts << %(<circle cx="#{pad_l + 86}" cy="#{pad_top - 26}" r="5" fill="#{DemoSupport::GREEN}"/>)
  parts << %(<text x="#{pad_l + 98}" y="#{pad_top - 22}" font-size="12.5" fill="#{DemoSupport::INK}">after</text>)

  swing = ->(s) { s.map { |(_, l)| l }.then { |v| v.max - v.min } }
  parts << (%(<text x="32" y="#{height - 18}" font-size="12.5" fill="#{DemoSupport::INK}">Loudest-to-quietest swing across the sitting: ) +
           %(<tspan fill="#{DemoSupport::RED}" font-weight="600">#{format('%.1f',
                                                                          swing.call(before_series))} LU</tspan> &#8594; ) +
           %(<tspan fill="#{DemoSupport::GREEN}" font-weight="600">#{format('%.1f',
                                                                            swing.call(after_series))} LU</tspan></text>))
  parts << '</svg>'
  parts.join("\n")
end

# --- Run ---

work = options[:work_dir]
FileUtils.rm_rf(work)
FileUtils.mkdir_p(work)
raw = File.join(work, 'raw')
norm = File.join(work, 'norm')
FileUtils.mkdir_p([raw, norm])

puts "Work dir: #{work}"

labels = nil
sources =
  if options[:source]
    exts = %w[.mkv .mp4 .m4v .avi .mov]
    found = Dir.glob(File.join(options[:source], '**', '*'))
               .select { |f| File.file?(f) && exts.include?(File.extname(f).downcase) }
               .sort.first(4)
    abort "Need at least 2 video files under #{options[:source]}" if found.size < 2

    labels = found.map { |f| File.basename(f, '.*')[0, 18] }
    found.each_with_index.map do |src, i|
      dest = File.join(raw, format('%02d%s', i + 1, File.extname(src)))
      FileUtils.cp(src, dest)
      dest
    end
  else
    labels = PLAYLIST.map { |p| p[:label] }
    puts "Generating #{PLAYLIST.size} synthetic clips (#{options[:duration]}s each)..."
    PLAYLIST.each_with_index.map do |p, i|
      DemoSupport.generate_clip(File.join(raw, format('%02d.mkv', i + 1)),
                                offset_lufs: p[:offset], duration: options[:duration], target: target)
    end
  end

# Boundaries come from actual clip durations, so real files line up too.
durations = sources.map do |f|
  out, = Open3.capture2e('ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                         '-of', 'csv=p=0', f)
  out.strip.to_f
end
boundaries = durations.each_with_object([0.0]) { |d, acc| acc << (acc.last + d) }[0...-1]

puts 'Building "before" playlist...'
before_file = DemoSupport.concat(sources, File.join(work, 'before.mkv'))

puts "Normalising copies (--profile #{options[:profile]})..."
normalised = sources.map do |f|
  dest = File.join(norm, File.basename(f))
  FileUtils.cp(f, dest)
  dest
end
DemoSupport.neutralise!(norm, options[:profile])

puts 'Building "after" playlist...'
after_file = DemoSupport.concat(normalised, File.join(work, 'after.mkv'))

puts 'Measuring loudness over time...'
before_series = DemoSupport.loudness_over_time(before_file)
after_series  = DemoSupport.loudness_over_time(after_file)
abort 'No loudness data captured' if before_series.empty? || after_series.empty?

sources.zip(normalised).each_with_index do |(a, b), i|
  puts format('  %-16s %6.1f -> %6.1f LUFS', labels[i][0, 16],
              DemoSupport.measure_lufs(a), DemoSupport.measure_lufs(b))
end

swing = ->(s) { s.map { |(_, l)| l }.then { |v| v.max - v.min } }
puts
puts format('swing across the sitting: %.1f LU -> %.1f LU',
            swing.call(before_series), swing.call(after_series))

File.write(options[:output], svg(before_series, after_series, boundaries, target, options[:profile], labels))
puts "Wrote #{options[:output]}"
puts "Listen: #{before_file} vs #{after_file}"
