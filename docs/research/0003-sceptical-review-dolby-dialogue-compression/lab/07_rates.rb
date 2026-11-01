# frozen_string_literal: true

# Do the rate figures flatter? The computed figure from the record is compared with a measurement of the same file,
# per stamp mode; then rate-sample's claim to test "a recipe", and the read-only claims.
require_relative 'lab'
require File.join(ROOT, 'spec/support/lra_fixture')

include Neutraliser # rubocop:disable Style/MixinUsage

work = Lab.dir('rate')
wav = Lab.programme_wav(File.join(work, 'p.wav'))
stream = Lab.encode(wav, File.join(work, 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
source = Lab.mux(stream, File.join(work, 'source.mkv'))
# Short bursts near full scale over a low bed: quiet overall, peaks already at the ceiling, so -20 is out of reach.
hot = File.join(work, 'hot.wav')
Lab.ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=color=pink:sample_rate=48000:seed=5:duration=40',
           '-af', "volume='if(lt(mod(t\\,10)\\,0.4)\\,1\\,0.06)':eval=frame,volume=14dB,alimiter=limit=0.9:level=0,aformat=channel_layouts=stereo", '-c:a', 'pcm_s24le', hot)
hot_stream = Lab.encode(hot, File.join(work, 'hot.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
hot_source = Lab.mux(hot_stream, File.join(work, 'hot.mkv'))
steady = Lab.surround_wav(File.join(work, 'steady.wav'), 'stereo', seconds: 30, db: -26)
steady_stream = Lab.encode(steady, File.join(work, 'steady.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
steady_source = Lab.mux(steady_stream, File.join(work, 'steady.mkv'))
puts format('hot clip: I %.1f, true peak %.1f, LRA %.1f', *Lab.levels(hot_source).values_at(:i, :true_peak, :lra))

rows = []
{ 'linear' => [source, []], 'linear, peak-capped' => [hot_source, []], 'limited' => [hot_source, ['--limit-db', 4]],
  'compressed' => [source, ['--lra-target', 10]], 'compressed + limiter' => [hot_source, ['--lra-target', 4, '--limit-db', 4]],
  'dynamic' => [source, ['--allow-dynamic']], 'dynamic --fast' => [source, ['--fast', '--allow-dynamic']] }.each do |name, (from, flags)|
  dir = Lab.dir('c')
  copy = File.join(dir, 'film.mkv')
  FileUtils.cp(from, copy)
  Lab.process(copy, *flags, '--tolerance', 0.5)
  computed = Report.new(copy, measure: false)
  measured = Report.new(copy, measure: true, dialogue_anchor: nil)
  c = computed.final_levels_for(computed.rows.first)
  m = measured.final_levels_for(measured.rows.first)
  e = Lab.levels(copy)
  rows << [name, computed.rows.first.state, Lab.f1(Lab.stamp(copy)&.gain_db), Lab.f1(e[:true_peak]), c ? Lab.f1(c.integrated) : 'n/j', c ? Lab.f1(c.lra) : 'n/j', Lab.f1(m.integrated), Lab.f1(m.lra), Lab.f1(e[:i]), Lab.f1(e[:lra]),
           c ? computed.rate.remote_free?(c) : 'n/j', measured.rate.remote_free?(m)]
end
Lab.table('Computed from the record vs measured (target -20, LRA limit 12)',
          %w[case state gain TP computed_I computed_LRA measured_I measured_LRA ebur_I ebur_LRA computed_verdict measured_verdict], rows)

# Who the denominator leaves out: two files that pass, and two the records can't place.
library = Lab.dir('mixed')
{ 'plain.mkv' => [steady_source, []], 'plain2.mkv' => [steady_source, []], 'limited.mkv' => [hot_source, ['--limit-db', 4]], 'imported.mkv' => [source, nil] }.each do |name, (from, flags)|
  copy = File.join(library, name)
  FileUtils.cp(from, copy)
  Lab.process(copy, *flags) if flags
end
File.write(File.join(library, 'm.jsonl'), "#{JSON.generate(file: 'imported.mkv', status: 'done', size: File.size(File.join(library, 'imported.mkv')), mtime: File.mtime(File.join(library, 'imported.mkv')).to_i)}\n")
Lab.cli('import-manifest', File.join(library, 'm.jsonl'), '--root', library)
puts "\nMixed library, computed:\n  #{Report.new(library, measure: false).rate.summary}"
puts "Same library, measured:\n  #{Report.new(library, measure: true, dialogue_anchor: nil).rate.summary}"

# rate-sample: does the recipe under test actually run on the sample?
stamped_lib = Lab.dir('stamped')
3.times do |i|
  copy = File.join(stamped_lib, "ep#{i}.mkv")
  FileUtils.cp(source, copy)
  Lab.process(copy)
end
untouched = File.join(stamped_lib, 'new.mkv')
FileUtils.cp(source, untouched)
snapshot = Lab.tree(stamped_lib)
log, code = Lab.cli('rate-sample', stamped_lib, '--sample', 4, '--seed', 1, '--allow-dynamic')
puts "\nrate-sample with --allow-dynamic over a part-swept library (exit #{code}):"
puts log.lines.grep(/\t|Remote-free|Run summary/).map { |line| "  #{line[0, 130].gsub(File.dirname(stamped_lib), '...')}" }
puts "  library unchanged: #{Lab.tree(stamped_lib) == snapshot}"

log, code = Lab.cli('rate-sample', stamped_lib, '--sample', 1, '--seed', 1, '--lra-target', 8)
puts "\nrate-sample --lra-target 8 (exit #{code}): #{log.lines.last(3).join.strip[0, 200]}"
log, code = Lab.cli('report', stamped_lib, '--lra-target', 8)
puts "report --lra-target 8 (exit #{code}): #{log.lines.first.to_s.strip[0, 160]}"

# Read-only claims.
film = Lab.dir('film')
LraFixture.build(File.join(film, 'film.mkv'), film)
snapshot = Lab.tree(film)
Lab.cli('report', film, '--measure')
Lab.cli('report', film)
puts "\nreport and report --measure left the folder byte and mtime identical: #{Lab.tree(film) == snapshot}"

# The dialogue estimate against a known truth: centre carries speech only, then also the effects.
def mix(path, dialogue_db:, effects_db:, centre_effects_db: nil)
  speech = "anoisesrc=color=pink:seed=11:sample_rate=48000:duration=40:amplitude=#{format('%.5f', 10**(dialogue_db / 20.0))}"
  fx = "anoisesrc=color=white:seed=12:sample_rate=48000:duration=40:amplitude=#{format('%.5f', 10**(effects_db / 20.0))}"
  gate = "volume='if(lt(mod(t\\,8)\\,3)\\,1\\,0)':eval=frame"
  centre_fx = centre_effects_db ? "+#{format('%.4f', 10**((centre_effects_db - effects_db) / 20.0))}*c1" : ''
  Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=40', '-f', 'lavfi', '-i', speech, '-f', 'lavfi', '-i', fx,
             '-filter_complex', "[1:a]#{gate}[d];[d][2:a]amerge=inputs=2,pan=5.1|c0=c1|c1=c1|c2=c0#{centre_fx}|c3=0*c0|c4=c1|c5=c1[m]",
             '-map', '0:v', '-map', '[m]', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'ac3', '-b:a', '640k', '-shortest', path)
  path
end

def truth_of_speech(dialogue_db)
  speech = File.join(Lab.dir('t'), 'speech.wav')
  Lab.ffmpeg('-f', 'lavfi', '-i', "anoisesrc=color=pink:seed=11:sample_rate=48000:duration=40:amplitude=#{format('%.5f', 10**(dialogue_db / 20.0))}",
             '-af', "volume='if(lt(mod(t\\,8)\\,3)\\,1\\,0)':eval=frame", speech)
  Lab.levels(speech, decoder: [])[:i]
end

rows = []
[['speech only in centre, quiet effects', -24, -40, nil], ['speech only in centre, loud effects', -24, -24, nil],
 ['centre also carries effects at -30', -24, -24, -30], ['centre also carries effects at -24', -24, -24, -24],
 ['centre carries effects at -18 (score up the middle)', -24, -24, -18]].each do |name, dialogue, effects, centre_fx|
  file = mix(File.join(Lab.dir('m'), 'film.mkv'), dialogue_db: dialogue, effects_db: effects, centre_effects_db: centre_fx)
  truth = truth_of_speech(dialogue)
  report = Report.new(file, measure: true)
  d = report.dialogue_for(report.rows.first)
  rows << [name, Lab.f1(truth), Lab.f1(d.estimate.level), Lab.f1(d.estimate.level - truth), Lab.f1(d.programme), Lab.f1(d.ldr), Lab.f1(d.programme - truth)]
end
Lab.table('Dialogue estimate against the real speech level', %w[mix true_speech estimate error programme ldr_reported ldr_true], rows)
