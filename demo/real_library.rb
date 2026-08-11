#!/usr/bin/env ruby
# frozen_string_literal: true

# Charts a *real* library, using data neutraliser already left behind.
#
#   ruby demo/real_library.rb --pairs pairs.tsv
#
# Every normalisation writes a `.loudnorm_<profile>.json` sidecar recording the
# file's loudness at analysis time. When the file is later normalised in place,
# that sidecar keeps the pre-normalisation number while the file on disk holds
# the result — so the pair is a genuine before/after from production, not a
# staged demo.
#
# Input is a TSV of `before_lufs<TAB>after_lufs<TAB>label`, which the operator
# produces by reading sidecars and re-measuring the current files (see
# demo/README.md). Kept separate from run.rb/ab.rb because the measuring
# happens wherever the library lives, not on this machine.

require 'optparse'
require_relative 'support'

options = { pairs: nil, profile: 'livingroom', output: File.join(DemoSupport::ROOT, 'demo', 'real-library.svg') }

OptionParser.new do |o|
  o.banner = 'Usage: ruby demo/real_library.rb --pairs FILE.tsv'
  o.on('--pairs FILE', 'TSV: before<TAB>after<TAB>label') { |v| options[:pairs] = v }
  o.on('--profile NAME', 'Profile these were normalised against') { |v| options[:profile] = v }
  o.on('--output PATH', 'Where to write the SVG') { |v| options[:output] = v }
  o.on('-h', '--help') do
    puts o
    exit
  end
end.parse!

abort 'Need --pairs FILE' unless options[:pairs] && File.exist?(options[:pairs])

target = DemoSupport.target_for(options[:profile])

rows = File.readlines(options[:pairs]).filter_map do |line|
  before, after, label = line.chomp.split("\t", 3)
  next if before.to_s.empty? || after.to_s.empty?

  { before: before.to_f, after: after.to_f, label: (label || '').strip }
end.sort_by { |r| r[:before] }

abort 'No usable rows' if rows.empty?

def svg(rows, target, _profile)
  width  = 840
  row_h  = 26
  pad_top = 116
  height = pad_top + (rows.size * row_h) + 62

  all = rows.flat_map { |r| [r[:before], r[:after]] } + [target]
  lo = all.min - 1.0
  hi = all.max + 1.0
  # Horizontal position encodes loudness; each film gets its own row so real
  # titles stay readable (the synthetic chart can overlap them; real ones can't).
  xl = ->(lufs, x0, x1) { x0 + ((lufs - lo) / (hi - lo) * (x1 - x0)) }

  parts = DemoSupport.svg_header(
    width, height,
    "A real library: #{rows.size} films, before and after",
    "measured with ffmpeg ebur128 &#183; \"before\" from neutraliser's own analysis sidecars &#183; target #{format('%.1f', target)} LUFS"
  )

  # Scale
  scale_y = pad_top - 30
  [-30, -25, -20, -15].each do |lufs|
    next unless lufs.between?(lo, hi)

    sx = xl.call(lufs, 300, width - 90).round(1)
    parts << (%(<line x1="#{sx}" y1="#{scale_y + 6}" x2="#{sx}" y2="#{pad_top + (rows.size * row_h) - 6}" ) +
             %(stroke="#{DemoSupport::GRID}" stroke-width="1"/>))
    parts << %(<text x="#{sx}" y="#{scale_y}" font-size="11" fill="#{DemoSupport::MUTED}" text-anchor="middle">#{lufs}</text>)
  end
  tx = xl.call(target, 300, width - 90).round(1)
  parts << (%(<line x1="#{tx}" y1="#{scale_y + 6}" x2="#{tx}" y2="#{pad_top + (rows.size * row_h) - 6}" ) +
           %(stroke="#{DemoSupport::GREEN}" stroke-width="1.5" stroke-dasharray="4 3" opacity="0.7"/>))
  parts << %(<text x="40" y="#{scale_y}" font-size="11" fill="#{DemoSupport::MUTED}">LUFS</text>)

  rows.each_with_index do |r, i|
    cy = pad_top + (i * row_h) + 4
    bx = xl.call(r[:before], 300, width - 90).round(1)
    ax = xl.call(r[:after], 300, width - 90).round(1)
    label = r[:label].length > 38 ? "#{r[:label][0, 37]}…" : r[:label]
    parts << %(<text x="288" y="#{cy + 4}" font-size="11.5" fill="#{DemoSupport::INK}" text-anchor="end">#{label}</text>)
    parts << %(<line x1="#{bx}" y1="#{cy}" x2="#{ax}" y2="#{cy}" stroke="#{DemoSupport::MUTED}" stroke-width="1.4" opacity="0.35"/>)
    parts << %(<circle cx="#{bx}" cy="#{cy}" r="4.5" fill="#{DemoSupport::RED}"/>)
    parts << %(<circle cx="#{ax}" cy="#{cy}" r="4.5" fill="#{DemoSupport::GREEN}"/>)
  end

  legend_y = pad_top - 52
  parts << %(<circle cx="306" cy="#{legend_y}" r="5" fill="#{DemoSupport::RED}"/>)
  parts << %(<text x="318" y="#{legend_y + 4}" font-size="12.5" fill="#{DemoSupport::INK}">before</text>)
  parts << %(<circle cx="386" cy="#{legend_y}" r="5" fill="#{DemoSupport::GREEN}"/>)
  parts << %(<text x="398" y="#{legend_y + 4}" font-size="12.5" fill="#{DemoSupport::INK}">after</text>)

  sb = rows.map { |r| r[:before] }
  sa = rows.map { |r| r[:after] }
  parts << (%(<text x="40" y="#{height - 22}" font-size="12.5" fill="#{DemoSupport::INK}">Spread: ) +
           %(<tspan fill="#{DemoSupport::RED}" font-weight="600">#{format('%.1f',
                                                                          sb.max - sb.min)} LU</tspan> &#8594; ) +
           %(<tspan fill="#{DemoSupport::GREEN}" font-weight="600">#{format('%.1f',
                                                                            sa.max - sa.min)} LU</tspan></text>))
  parts << '</svg>'
  parts.join("\n")
end

sb = rows.map { |r| r[:before] }
sa = rows.map { |r| r[:after] }
rows.each { |r| puts format('%-34s %6.1f -> %6.1f', r[:label][0, 34], r[:before], r[:after]) }
puts
puts format('spread: %.1f LU -> %.1f LU', sb.max - sb.min, sa.max - sa.min)
puts format('worst deviation from target: %.1f LU', sa.map { |v| (v - target).abs }.max)

File.write(options[:output], svg(rows, target, options[:profile]))
puts "Wrote #{options[:output]}"
