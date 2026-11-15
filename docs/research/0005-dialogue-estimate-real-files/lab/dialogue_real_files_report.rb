# Research 0005 analysis: reads data/results.jsonl, prints the tables the note quotes (markdown).
#   ruby dialogue_real_files_report.rb > ../data/tables.md   (ONLY_PLAN=1 for the first sample alone)
require 'json'
require_relative '../../../../lib/neutraliser'

DATA = File.expand_path('../data', __dir__)
rows = File.readlines(File.join(DATA, 'results.jsonl')).map { |l| JSON.parse(l, symbolize_names: true) }
errors = rows.select { |r| r[:error] }
rows -= errors
# ONLY_PLAN=1: just the stratified random first sample (plan.json), not the files picked for a real dialnorm / songs / score
if ENV['ONLY_PLAN']
  ids = JSON.parse(File.read(File.join(DATA, 'plan.json')))['picks'].map { |p| p['plex_id'].to_s }
  rows = rows.select { |r| ids.include?(r[:plex_id].to_s) }
end
Meas = Struct.new(:input_i, :input_tp)

def q(xs, p) = xs.empty? ? nil : xs.sort[((xs.size - 1) * p).round]
def f(x, d = 1) = x.nil? ? '-' : format("%.#{d}f", x)
def stats(xs) = xs.empty? ? 'n=0' : "n=#{xs.size}, median #{f(q(xs, 0.5))}, p10 #{f(q(xs, 0.1))}, p90 #{f(q(xs, 0.9))}, min #{f(xs.min)}, max #{f(xs.max)}"

rows.each do |r|
  r[:ch] = r[:track][:channels].to_i
  r[:surround] = r[:ch] >= 3
  r[:est] = r.dig(:estimate, :level)
  r[:prog] = r.dig(:programme, :i)
  r[:ldr] = r[:est] && r[:prog] ? r[:prog] - r[:est] : nil
  r[:dolby] = %w[ac3 eac3].include?(r[:track][:codec])
end

puts "## Sample\n\n#{rows.size} files measured (#{errors.size} failed: #{errors.map { |e| e[:title] }.join('; ')})\n\n"
puts '| kind | group | codec | ch | n |', '|---|---|---|---|---|'
rows.group_by { |r| [r[:kind], r[:group], r[:track][:codec], r[:ch]] }.sort_by { |k, _| k.map(&:to_s) }.each { |k, v| puts "| #{k.join(' | ')} | #{v.size} |" }

puts "\n## 1. Estimate vs dialnorm (Dolby tracks, 5.1 and up)\n\n"
dol = rows.select { |r| r[:dolby] && r[:surround] }
puts "Dolby surround tracks: #{dol.size}; dialnorm read: #{dol.count { |r| r[:dialnorm] }}; dialnorm -31 (unset, no ground truth): #{dol.count { |r| r[:dialnorm] == -31 }}; stamped by neutraliser: #{dol.count { |r| r[:stamped] }}"
puts "dialnorm values: #{dol.map { |r| r[:dialnorm] }.tally.sort_by { |k, _| k.to_i }.to_h}\n\n"
gt = dol.select { |r| r[:dialnorm] && r[:dialnorm] != -31 && r[:est] }
puts '| title | kind | dialnorm | estimate | est - dialnorm | programme | LRA |', '|---|---|---|---|---|---|---|'
gt.sort_by { |r| (r[:est] - r[:dialnorm]).abs }.each do |r|
  puts "| #{r[:title]} | #{r[:kind]} | #{r[:dialnorm]} | #{f(r[:est])} | #{f(r[:est] - r[:dialnorm])} | #{f(r[:prog])} | #{f(r.dig(:programme, :lra))} |"
end
deltas = gt.map { |r| r[:est] - r[:dialnorm] }
within = deltas.count { |d| d.abs <= 2 }
puts "\nFiles with usable dialnorm: #{gt.size}. Within 2 LU: #{within} (#{f(100.0 * within / [gt.size, 1].max)}%). Within 3 LU: #{deltas.count { |d| d.abs <= 3 }}. Bias (est - dialnorm): #{stats(deltas)}"
puts "Pass mark (>= 90% within 2 LU): #{gt.empty? ? 'n/a' : (within.fdiv(gt.size) >= 0.9 ? 'PASS' : 'FAIL')}"
%w[movie episode].each do |k|
  d = gt.select { |r| r[:kind] == k }.map { |r| r[:est] - r[:dialnorm] }
  puts "- #{k}s: #{stats(d)}; within 2 LU: #{d.count { |x| x.abs <= 2 }} of #{d.size}"
end
scr_path = File.join(DATA, 'screen.jsonl')
if File.exist?(scr_path)
  scr = File.readlines(scr_path).map { |l| JSON.parse(l, symbolize_names: true) }.reject { |r| r[:error] || r[:dialnorm].nil? }
  scr_ep = scr.select { |r| r[:kind] == 'episode' }
  scr_mv = scr.select { |r| r[:kind] == 'movie' }
  real = ->(set) { set.count { |r| r[:dialnorm] != -31 } }
  puts "\nScreen of Dolby 5.1 files (first frames only, dialnorm readable): #{scr.size}; dialnorm -31: #{scr.size - real.call(scr)}; real value: #{real.call(scr)} (#{f(100.0 * real.call(scr) / scr.size)}%). Movies #{real.call(scr_mv)} of #{scr_mv.size}, episodes #{real.call(scr_ep)} of #{scr_ep.size}. Values: #{scr.map { |r| r[:dialnorm] }.tally.sort_by { |k, _| k }.to_h}"
end

puts "\n## 1b. Subtitle-cue reference (all files with enough cues)\n\n"
cu = rows.select { |r| r[:cue_ref] && r[:est] }
puts '| title | kind | cues | coverage | shift s | separation dB (at 0) | est | cue full-mix | cue centre | est - cue full | est - cue centre | dialnorm - cue full |', '|---|---|---|---|---|---|---|---|---|---|---|---|'
cu.each do |r|
  c = r[:cue_ref]
  puts "| #{r[:title]} | #{r[:kind]} | #{r.dig(:cues, :count)} | #{f(c[:coverage] * 100, 0)}% | #{r[:sync][:shift]} | #{f(r[:sync][:separation])} (#{f(r[:sync][:separation_at_zero])}) | #{f(r[:est])} | #{f(c[:full_mix])} | #{f(c[:centre])} | #{f(c[:full_mix] && r[:est] - c[:full_mix])} | #{f(c[:centre] && r[:est] - c[:centre])} | #{r[:dialnorm] && r[:dialnorm] != -31 ? f(r[:dialnorm] - c[:full_mix]) : '-'} |"
end
good = cu.select { |r| r[:sync][:separation] >= 3 }
[['all with cues', cu], ['sync separation >= 3 dB', good]].each do |label, set|
  d = set.filter_map { |r| r[:cue_ref][:full_mix] && r[:est] - r[:cue_ref][:full_mix] }
  puts "\n#{label}: est - cue full-mix: #{stats(d)}; within 2 LU: #{d.count { |x| x.abs <= 2 }} of #{d.size}"
  d2 = set.select { |r| r[:dialnorm] && r[:dialnorm] != -31 }.map { |r| r[:dialnorm] - r[:cue_ref][:full_mix] }
  puts "#{label}: dialnorm - cue full-mix (how good is the cue reference, where dialnorm exists): #{stats(d2)}"
end

%w[movie episode].each do |k|
  set = cu.select { |r| r[:kind] == k }
  d = set.filter_map { |r| r[:cue_ref][:full_mix] && r[:est] - r[:cue_ref][:full_mix] }
  puts "\n#{k}s with cues: est - cue full-mix: #{stats(d)}; within 2 LU: #{d.count { |x| x.abs <= 2 }} of #{d.size}; over-reads by more than 2 LU: #{d.count { |x| x > 2 }}; under-reads by more than 2 LU: #{d.count { |x| x < -2 }}"
end
shifts = cu.map { |r| r[:sync][:shift].abs }
puts "\nSync of the cues: |best shift| median #{f(q(shifts, 0.5))} s, max #{f(shifts.max)} s; shift of 0.0 to 0.2 s in #{shifts.count { |x| x <= 0.2 }} of #{shifts.size}; separation (speech blocks minus other blocks, centre channel) median #{f(q(cu.map { |r| r[:sync][:separation] }, 0.5))} dB; under 3 dB in #{cu.count { |r| r[:sync][:separation] < 3 }}: #{cu.select { |r| r[:sync][:separation] < 3 }.map { |r| r[:title] }.join('; ')}"
puts "Cue coverage of runtime: #{stats(cu.map { |r| r[:cue_ref][:coverage] * 100 })}"
puts "Files with an English text subtitle track chosen: #{rows.count { |r| r[:subtitle] }} of #{rows.size}; with 30 or more speech cues: #{cu.size + rows.count { |r| r[:cue_ref] && !r[:est] }}"

puts "\n## 3. Loudness above dialogue (programme - centre estimate), 5.1 and up\n\n"
ldrs = rows.select { |r| r[:surround] && r[:ldr] }.map { |r| r[:ldr] }
puts stats(ldrs)
puts "\n| LU above dialogue | files |", '|---|---|'
[[-99, 0], [0, 2], [2, 4], [4, 6], [6, 8], [8, 10], [10, 99]].each do |lo, hi|
  puts "| #{lo <= -99 ? 'under 0 (centre louder than mix)' : hi >= 99 ? '10 and over' : "#{lo} to #{hi}"} | #{ldrs.count { |x| x >= lo && x < hi }} |"
end
puts "\nOver the 5 LU EBU R 128 s4 limit: #{ldrs.count { |x| x > 5 }} of #{ldrs.size}. Programme LRA (all files): #{stats(rows.map { |r| r.dig(:programme, :lra) }.compact)}"

puts "\n## 3b. What each target would ask of the files\n\n"
tol = 1.0
[-27.0, -24.0].each do |target|
  profile = { lufs: -20.0, tp: -1.5, anchor: :dialogue, dialogue_target: target }
  res = rows.map do |r|
    est = r[:est] ? Neutraliser::DialogueEstimate.centre_channel(r[:est]) : Neutraliser::DialogueEstimate.unavailable('none')
    aim = Neutraliser::Ladder.aim(profile, r[:prog], est)
    aimed = r[:est] ? aim[:lufs] : target + Neutraliser::Ladder::NO_DIALOGUE_OFFSET_LU # stereo/no estimate
    plan = Neutraliser::GainPlan.for(Meas.new(r[:prog], r.dig(:programme, :tp)), aim.merge(lufs: aimed), limit_db: Neutraliser::Ladder::LIMIT_DB)
    { r: r, aimed: aimed, plan: plan, move: aimed - r[:prog] }
  end
  moved = res.select { |x| x[:move].abs > tol }
  up = res.select { |x| x[:move] > tol }
  puts "### Dialogue #{target.to_i} (fallback programme #{(target + 3).to_i} when no estimate)\n\n"
  puts "- files that would move by more than #{tol} LU: #{moved.size} of #{res.size} (#{up.size} louder, #{moved.size - up.size} quieter)"
  puts "- need the peak limiter at all (limit 6): #{res.count { |x| x[:plan].limited }}; need gain beyond the 6 dB limiter (shortfall > 0.5 LU): #{res.count { |x| x[:plan].shortfall > 0.5 }}; shortfall > 0: #{res.count { |x| x[:plan].shortfall.positive? }}"
  puts "- need > 6 dB of gain: #{res.count { |x| x[:move] > 6 }}; need > 6 dB of cut: #{res.count { |x| x[:move] < -6 }}"
  est_only = res.select { |x| x[:r][:est] }
  puts "- with a dialogue estimate (#{est_only.size}): shortfall > 0.5 LU: #{est_only.count { |x| x[:plan].shortfall > 0.5 }}; limited: #{est_only.count { |x| x[:plan].limited }}"
  lv20 = res.select { |x| (x[:r][:prog] - -20.0).abs <= tol }
  puts "- files already within #{tol} LU of -20 programme (\"levelled to -20\"): #{lv20.size}; of those, would change: #{lv20.count { |x| x[:move].abs > tol }}"
  lv20e = lv20.select { |x| x[:r][:est] }
  puts "  - of those, with a dialogue estimate (#{lv20e.size}): would change #{lv20e.count { |x| x[:move].abs > tol }}; median move #{f(q(lv20e.map { |x| x[:move] }, 0.5))} LU"
  stamped = res.select { |x| x[:r][:stamped] }
  puts "- carrying a neutraliser stamp: #{stamped.size}"
  puts "- move distribution (LU): #{stats(res.map { |x| x[:move] })}\n\n"
  worst = res.select { |x| x[:plan].shortfall > 0.5 }.sort_by { |x| -x[:plan].shortfall }.first(8)
  worst.each { |x| puts "  - short of target: #{x[:r][:title]}: programme #{f(x[:r][:prog])}, TP #{f(x[:r].dig(:programme, :tp))}, estimate #{f(x[:r][:est])}, shortfall #{f(x[:plan].shortfall)}" }
  puts
end

puts "## Programme level now (all files)\n\n#{stats(rows.map { |r| r[:prog] }.compact)}\n"
puts "Within 1 LU of -20: #{rows.count { |r| (r[:prog] + 20).abs <= 1 }} of #{rows.size}; within 2 LU: #{rows.count { |r| (r[:prog] + 20).abs <= 2 }}"
puts "\n## Estimates unavailable\n\n#{rows.reject { |r| r[:est] }.map { |r| "#{r[:title]}: #{r.dig(:estimate, :reason)}" }.join("\n")}"
