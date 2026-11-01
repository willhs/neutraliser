#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs `neutraliser process --lra-target N` over the synthetic 5.1 fixture
# (spec/support/lra_fixture.rb) at several targets, with and without a centre
# boost, and prints what each run did as a Markdown table. Every figure is read
# back from the output file with ebur128, a different filter from the loudnorm
# pass that chose the rung. Synthetic pink-noise scenes: this checks the
# arithmetic of the ladder (LRA, level, peak), not how anything sounds.
#
#   bundle exec ruby demo/compression_ladder.rb [target ...]   (default: 12 10 8 6)

require 'tmpdir'
require 'fileutils'
require_relative '../spec/support/lra_fixture'
require_relative '../lib/neutraliser'

targets = ARGV.empty? ? [12, 10, 8, 6] : ARGV.map(&:to_f)
rows = []

Dir.mktmpdir do |dir|
  source = LraFixture.build(File.join(dir, 'source.mkv'), dir)
  levels = LraFixture.measure(source)
  rows << ['source (untouched)', '-', nil, levels, nil]

  variants = targets.flat_map { |target| [[target, nil], [target, 4.0]] }
  variants.each do |target, boost|
    copy = File.join(dir, "t#{target}-#{boost || 0}.mkv")
    FileUtils.cp(source, copy)
    args = ['process', '--replace', '--lra-target', target.to_s, *(boost ? ['--centre-boost', boost.to_s] : []), copy]
    $stdout = File.open(File::NULL, 'w')
    begin
      Neutraliser::CLI.start(args)
    ensure
      $stdout = STDOUT
    end
    stamp = Neutraliser::FFmpegWrapper.read_stamp(copy)
    name = "--lra-target #{target.to_i}"
    name += " --centre-boost #{boost.to_i}" if boost
    rows << [name, stamp&.compression || 'none',
             stamp&.lra_after, LraFixture.measure(copy), stamp]
  end
end

puts '| run | rung | LRA after (loudnorm, before encode) | I (LUFS) | LRA (LU) | peak (dBFS) |'
puts '|---|---|---|---|---|---|'
rows.each do |name, rung, predicted, out, _stamp|
  puts "| #{name} | #{rung} | #{predicted ? format('%.1f', predicted) : '-'} | " \
       "#{format('%.1f', out[:i])} | #{format('%.1f', out[:lra])} | #{format('%.1f', out[:peak])} |"
end
