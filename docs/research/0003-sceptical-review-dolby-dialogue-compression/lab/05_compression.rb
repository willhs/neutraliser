# frozen_string_literal: true

# Does the ladder's bisection land where it says, and does anything clip? All six rungs are measured on clips of
# different shapes, to test the claim the bisection rests on ("LRA falls monotonically down the ladder"), then the
# chosen rung is compared with a brute-force search. End-to-end runs are read back with ebur128.
require_relative 'lab'
require File.join(ROOT, 'spec/support/lra_fixture')

include Neutraliser # rubocop:disable Style/MixinUsage

PROFILE = Profiles.get_profile('livingroom')

def steps_wav(path, steps)
  inputs = steps.flat_map { |seconds, db| ['-f', 'lavfi', '-i', "anoisesrc=color=pink:duration=#{seconds}:sample_rate=48000:amplitude=#{format('%.5f', 10**(db / 20.0))}"] }
  graph = "#{steps.each_index.map { |i| "[#{i}:a]" }.join}concat=n=#{steps.size}:v=0:a=1,aformat=channel_layouts=stereo[mix]"
  Lab.ffmpeg(*inputs, '-filter_complex', graph, '-map', '[mix]', '-c:a', 'pcm_s24le', path)
  path
end

def clip(name, steps)
  dir = Lab.dir('clip')
  stream = Lab.encode(steps_wav(File.join(dir, 'a.wav'), steps), File.join(dir, 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
  [name, Lab.mux(stream, File.join(dir, 'film.mkv'))]
end

film = Lab.dir('film')
LraFixture.build(File.join(film, 'film.mkv'), film)
clips = [
  ['film-like 5.1 (LraFixture)', File.join(film, 'film.mkv')],
  clip('two levels, 20 LU apart', ([[6, -34], [3, -14]] * 5)),
  clip('loud bursts over a very quiet bed (bed under the gate)', ([[6, -48], [6, -12]] * 4)),
  clip('three levels, quiet tail 30 dB down', ([[6, -14], [6, -24], [6, -44]] * 4)),
  clip('quiet file, -45 LUFS range', ([[6, -58], [4, -36]] * 4)),
  clip('hot file, peaks near full scale', ([[6, -28], [4, -3]] * 4)),
  clip('narrow steps, 6 LU', ([[6, -24], [6, -18]] * 4))
]

rows = []
clips.each do |name, path|
  track = Neutraliser::Source.new(path).primary_track
  before = FFmpegWrapper.measure_loudness(path, target_i: PROFILE[:lufs], target_tp: PROFILE[:tp], target_lra: PROFILE[:lra], audio_index: track[:index])
  lras = Compression::LADDER.map do |rung|
    FFmpegWrapper.measure_loudness(path, target_i: PROFILE[:lufs], target_tp: PROFILE[:tp], target_lra: PROFILE[:lra],
                                         audio_index: track[:index], pre_filter: rung.filter(before.input_i)).input_lra
  end
  monotonic = lras.each_cons(2).all? { |a, b| b <= a + 0.05 }
  # Every whole-number limit the ladder spans: does bisection agree with looking at every rung?
  limits = (lras.min.floor..lras.max.ceil).to_a
  wrong = limits.select do |limit|
    bisect = Compression.first_rung_within(limit, ->(i) { Struct.new(:input_lra).new(lras[i]) })
    bisect != lras.index { |lra| lra <= limit }
  end
  rows << [name, Lab.f1(before.input_i), Lab.f1(before.input_lra), lras.map { |lra| Lab.f1(lra) }.join(' '), monotonic, wrong.empty? ? 'agrees' : "differs at #{wrong.join(',')}"]
end
Lab.table('LRA per rung, gentle to extreme (loudnorm through the same chain)', %w[clip I LRA rungs monotonic bisection_vs_brute_force], rows)

# End to end: target -20, driver flags plus --lra-target. Does it land, and does it clip?
rows = []
clips.each do |name, path|
  [[10, []], [10, ['--limit-db', 4]], [6, []], [6, ['--limit-db', 4]]].each do |target, flags|
    copy = File.join(Lab.dir('c'), File.basename(path))
    FileUtils.cp(path, copy)
    log, code = Lab.process(copy, '--lra-target', target, *flags)
    stamp = Lab.stamp(copy)
    src = Lab.levels(path)
    out = Lab.levels(copy)
    rows << [name[0, 24], target, flags.join(' '), code, stamp&.mode, stamp&.compression, Lab.f1(src[:lra]), Lab.f1(stamp&.lra_after), Lab.f1(out[:lra]),
             Lab.f1(out[:i]), Lab.f1(stamp&.gain_db), Lab.f1(out[:true_peak]), Lab.f1(out[:sample_peak]),
             log[/Warning: (even the strongest|no compression reaches)/] ? 'not reached' : '']
  end
end
Lab.table('End to end, livingroom (-20 LUFS, -1.5 dBTP)',
          %w[clip target flags exit mode rung src_LRA lra_after out_LRA out_I gain TP sample_peak note], rows)

# A rerun must not stack, and a stricter rerun must not either.
copy = File.join(Lab.dir('c'), 'film.mkv')
FileUtils.cp(clips[1][1], copy)
Lab.process(copy, '--lra-target', 10)
sha = Lab.sha(copy)
log1, = Lab.process(copy, '--lra-target', 10)
log2, = Lab.process(copy, '--lra-target', 6)
log3, = Lab.process(copy)
puts "\nRerun same target: bytes #{Lab.sha(copy) == sha ? 'same' : 'CHANGED'}; stricter target: same (#{log2[/Already processed/]}); without the flag: same (#{log3[/Already processed/]})"
