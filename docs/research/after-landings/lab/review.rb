# frozen_string_literal: true

# Synthetic-only reproduction kit for the 15 Nov review. Run from the repo root:
#   bundle exec ruby docs/research/after-landings/lab/review.rb /absolute/new/scratch-directory
# Refuses an existing directory. No media input paths or library access.
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require_relative '../../../../lib/neutraliser'
require_relative '../../../../spec/support/ladder_fixture'

root = File.expand_path(ARGV.fetch(0))
Dir.mkdir(root)
fixtures = File.join(root, 'fixtures')
Dir.mkdir(fixtures)
%i[narrow peaky wide dts dialogue].each { |kind| LadderFixture.build(kind, File.join(fixtures, "#{kind}.mkv")) }

def generate(path, pan)
  LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                 '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=12:rate=10',
                 '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=12:sample_rate=48000:amplitude=0.1:seed=1',
                 '-filter_complex', "[1:a]#{pan}[a]", '-map', '0:v', '-map', '[a]',
                 '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'pcm_s24le', path)
end

generate(File.join(fixtures, 'mono.mkv'), 'pan=mono|c0=0.2*c0')
generate(File.join(fixtures, 'five1.mkv'), 'pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0')
generate(File.join(fixtures, 'nocentre.mkv'), 'pan=5.1|c0=c0|c1=c0|c4=c0|c5=c0')
# Front/back channels quiet, side channels loud: loudnorm omits the loud sides.
generate(File.join(fixtures, 'sev1.mkv'), 'pan=7.1|c0=0.2*c0|c1=0.2*c0|c2=0.2*c0|c3=0.2*c0|c4=0.2*c0|c5=0.2*c0|c6=c0|c7=c0')
LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', File.join(fixtures, 'wide.mkv'),
               '-map', '0:v', '-map', '0:a:0', '-c:v', 'copy', '-af',
               'pan=7.1|c0=c0|c1=c1|c2=c2|c3=c3|c4=c4|c5=c5|c6=c4|c7=c5',
               '-c:a', 'pcm_s24le', File.join(fixtures, 'wide71.mkv'))

def meters(path)
  plain = Neutraliser::FFmpegWrapper.measure_loudness(path)
  text = LraFixture.run!('ffmpeg', '-hide_banner', '-nostats', *Neutraliser::DolbyStream::DRC_OFF,
                        '-i', path, '-map', '0:a:0', '-af', 'ebur128=peak=true', '-f', 'null', '-')
  summary = text[/Summary:.*\z/m] or raise 'missing ebur128 summary'
  eb_i = Float(summary[/^\s+I:\s+(-?[\d.]+) LUFS/, 1])
  eb_lra = Float(summary[/^\s+LRA:\s+(-?[\d.]+) LU/, 1])
  { loudnorm_i: plain.input_i, ebur128_i: eb_i, delta: (eb_i - plain.input_i).round(2),
    loudnorm_lra: plain.input_lra, ebur128_lra: eb_lra }
end

Dir.glob(File.join(fixtures, '*.mkv')).sort.each do |file|
  puts JSON.generate(file: File.basename(file), meters: meters(file))
end

cli = File.expand_path('../../../../bin/neutraliser', __dir__)
scenarios = {
  'gain' => ['narrow', [%w[--ladder], %w[--ladder], []]],
  'limit' => ['peaky', [%w[--ladder]]],
  'compress' => ['wide', [%w[--ladder], %w[--ladder]]],
  'convert' => ['dts', [%w[--ladder --allow-codec-change]]],
  'recipe-switch' => ['wide', [[], %w[--ladder], %w[--ladder]]],
  'mono' => ['mono', [%w[--ladder --anchor dialogue]]],
  'stereo-dialogue' => ['narrow', [%w[--ladder --anchor dialogue]]],
  'silent-centre' => ['nocentre', [%w[--ladder --anchor dialogue]]],
  'sides' => ['sev1', [%w[--ladder], %w[--ladder]]],
  'wide-sides' => ['wide71', [%w[--ladder]]],
  'extreme-dialogue' => ['sev1', [%w[--ladder --anchor dialogue]]],
  'dialogue' => ['dialogue', [%w[--ladder --anchor dialogue]]],
  'fast-refused' => ['narrow', [%w[--ladder --fast]]],
  'fast-allowed' => ['narrow', [%w[--ladder --fast --allow-dynamic]]],
  'redo-current-refused' => ['narrow', [%w[--ladder --redo-recipe 3]]],
  'redo-old' => ['narrow', [[], %w[--ladder --redo-recipe 2]]]
}
scenarios.each do |name, (fixture, runs)|
  dir = File.join(root, name)
  Dir.mkdir(dir)
  file = File.join(dir, 'clip.mkv')
  FileUtils.cp(File.join(fixtures, "#{fixture}.mkv"), file)
  runs.each_with_index do |flags, index|
    output, status = Open3.capture2e(RbConfig.ruby, cli, 'process', '--replace', *flags, file)
    File.write(File.join(dir, "run#{index}.txt"), output)
    puts JSON.generate(scenario: name, flags: flags, exit: status.exitstatus,
                       stamp: Neutraliser::Source.new(file).stamp&.to_h, meters: meters(file))
  end
  output, status = Open3.capture2e(RbConfig.ruby, cli, 'report', '--measure', '--format', 'json', file)
  File.write(File.join(dir, 'report.json'), output)
  raise "report failed: #{output}" unless status.success?
end
