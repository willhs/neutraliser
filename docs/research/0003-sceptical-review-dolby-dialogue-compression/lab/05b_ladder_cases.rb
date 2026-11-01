# frozen_string_literal: true

# The cases 05_compression.rb's rung table predicts, through the real CLI, and the two LRA meters against the
# EBU Tech 3342 test signals (their expected LRA is known), because every --lra-target decision and the rate rest on
# the meter.
require_relative 'lab'

include Neutraliser # rubocop:disable Style/MixinUsage

def steps_wav(path, steps)
  inputs = steps.flat_map { |seconds, db| ['-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{seconds}:sample_rate=48000:amplitude=#{format('%.5f', 10**(db / 20.0))}"] }
  graph = "#{steps.each_index.map { |i| "[#{i}:a]" }.join}concat=n=#{steps.size}:v=0:a=1,aformat=channel_layouts=stereo[mix]"
  Lab.ffmpeg(*inputs, '-filter_complex', graph, '-map', '[mix]', '-c:a', 'pcm_s24le', path)
  path
end

def clip(steps)
  dir = Lab.dir('clip')
  stream = Lab.encode(steps_wav(File.join(dir, 'a.wav'), steps), File.join(dir, 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
  Lab.mux(stream, File.join(dir, 'film.mkv'))
end

rows = []
{ 'three levels, quiet tail' => [([[6, -14], [6, -24], [6, -44]] * 4), 8, 2],
  'loud bursts, bed under the gate' => [([[6, -48], [6, -12]] * 4), 3, 1] }.each do |name, (steps, target, tolerance)|
  file = clip(steps)
  src = Lab.levels(file)
  loudnorm = FFmpegWrapper.measure_loudness(file).input_lra
  copy = File.join(Lab.dir('c'), 'film.mkv')
  FileUtils.cp(file, copy)
  log, = Lab.process(copy, '--lra-target', target, '--tolerance', tolerance)
  stamp = Lab.stamp(copy)
  rows << [name, "#{target}+#{tolerance}", Lab.f1(loudnorm), stamp&.compression || '-', Lab.f1(stamp&.lra_after), Lab.f1(src[:lra]), Lab.f1(Lab.levels(copy)[:lra]), log[/Warning: (even the strongest|no compression reaches)[^\n]*/].to_s[0, 60]]
end
Lab.table('What the run picked', %w[clip limit loudnorm_src rung lra_after ebur_src ebur_out warning], rows)

# EBU Tech 3342, cases 1-4: stereo 1 kHz sine at the stated level (0 LUFS is -3.01 dBFS per channel... a stereo pair reads +3 over mono).
rows = []
[[1, [[20, -20], [20, -30]], 10], [2, [[20, -20], [20, -15]], 5], [3, [[20, -40], [20, -20]], 20],
 [4, [[20, -50], [20, -35], [20, -20], [20, -35], [20, -50]], 15]].each do |number, parts, expected|
  dir = Lab.dir('ebu')
  wav = File.join(dir, 'case.wav')
  inputs = parts.flat_map { |seconds, _| ['-f', 'lavfi', '-i', "sine=frequency=1000:sample_rate=48000:duration=#{seconds}"] }
  # sine's amplitude is 1/8 (-18.06 dBFS); stereo 1 kHz at A dBFS per channel reads A - 0.691 + 3.01 + ... calibrated below.
  chains = parts.each_with_index.map { |(_, lufs), i| "[#{i}:a]volume=#{format('%.3f', lufs + 18.06 - 3.01 + 0.0)}dB,aformat=channel_layouts=stereo[s#{i}]" }
  labels = parts.each_index.map { |i| "[s#{i}]" }.join
  Lab.ffmpeg(*inputs, '-filter_complex', "#{chains.join(';')};#{labels}concat=n=#{parts.size}:v=0:a=1[m]", '-map', '[m]', '-c:a', 'pcm_f32le', wav)
  ebur = Lab.levels(wav, decoder: [])[:lra]
  loudnorm = FFmpegWrapper.measure_loudness(wav).input_lra
  rows << ["Tech 3342 case #{number}", expected, Lab.f1(ebur), Lab.f1(loudnorm), Lab.f1(loudnorm - expected)]
end
Lab.table('LRA meters against the known answer (tolerance in the spec: +/-1 LU)', %w[signal expected ebur128 loudnorm loudnorm_error], rows)
