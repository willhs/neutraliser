# frozen_string_literal: true

# How sharp is LRA's cliff at its gate, and what do the two meters say on 7.1? Numbers the note quotes, on their own so
# they can be rerun without the slow end-to-end tables.
require_relative 'lab'

include Neutraliser # rubocop:disable Style/MixinUsage

def steps_clip(steps, seed: nil)
  dir = Lab.dir('clip')
  wav = File.join(dir, 'a.wav')
  inputs = steps.each_with_index.flat_map do |(seconds, db), i|
    seed_opt = seed ? "seed=#{seed + i}:" : ''
    ['-f', 'lavfi', '-i', "anoisesrc=color=pink:#{seed_opt}duration=#{seconds}:sample_rate=48000:amplitude=#{format('%.5f', 10**(db / 20.0))}"]
  end
  graph = "#{steps.each_index.map { |i| "[#{i}:a]" }.join}concat=n=#{steps.size}:v=0:a=1,aformat=channel_layouts=stereo[mix]"
  Lab.ffmpeg(*inputs, '-filter_complex', graph, '-map', '[mix]', '-c:a', 'pcm_s24le', wav)
  stream = Lab.encode(wav, File.join(dir, 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
  Lab.mux(stream, File.join(dir, 'film.mkv'))
end

# The same recipe of steps, only the noise differs.
rows = (1..6).map do |seed|
  file = steps_clip([[6, -14], [6, -24], [6, -44]] * 4, seed: seed)
  before = FFmpegWrapper.measure_loudness(file)
  rungs = Compression::LADDER.first(2).map { |rung| FFmpegWrapper.measure_loudness(file, pre_filter: rung.filter(before.input_i)).input_lra }
  [seed, Lab.f1(before.input_i), Lab.f1(before.input_lra), Lab.f1(Lab.levels(file)[:lra]), Lab.f1(rungs[0]), Lab.f1(rungs[1])]
end
Lab.table('Same steps, six noise seeds', %w[seed I loudnorm_LRA ebur128_LRA gentle moderate], rows)

# Two levels 28 dB apart, one on each side of the gate: where the meters part.
wav = Lab.programme_wav(File.join(Lab.dir('g'), 'p.wav'), quiet_db: -30, loud_db: -2)
stream = Lab.encode(wav, File.join(Lab.dir('g'), 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
film = Lab.mux(stream, File.join(Lab.dir('g'), 'film.mkv'))
puts format("\nTwo levels on either side of the gate: loudnorm LRA %.1f, ebur128 LRA %.1f", FFmpegWrapper.measure_loudness(film).input_lra, Lab.levels(film)[:lra])

# 7.1: the same noise on all eight channels, read by both.
seven = Lab.surround_wav(File.join(Lab.dir('s'), 's.wav'), '7.1', seconds: 10, db: -20)
five = Lab.surround_wav(File.join(Lab.dir('s'), 's.wav'), '5.1', seconds: 10, db: -20)
puts format('7.1: loudnorm %.1f, ebur128 %.1f. 5.1: loudnorm %.1f, ebur128 %.1f', FFmpegWrapper.measure_loudness(seven).input_i, Lab.levels(seven, decoder: [])[:i],
            FFmpegWrapper.measure_loudness(five).input_i, Lab.levels(five, decoder: [])[:i])
