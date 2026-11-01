# frozen_string_literal: true

# Do recipe stamps skip or redo the right files? A library is built with the real older code (git archive of the
# commit before recipes, and of the last recipe-1 commit), so the stamps and the damage are the real thing, then the
# current CLI runs over it. "changed" means the file's bytes changed.
require_relative 'lab'

def old_code(sha)
  dir = Lab.dir("old-#{sha}")
  Lab.run!('sh', '-c', "git -C #{ROOT} archive #{sha} lib bin | tar -x -C #{dir}")
  File.join(dir, 'bin/neutraliser')
end

UNVERSIONED_SHA = '23376c2' # the commit before dbfb20e
RECIPE1_SHA = '5b82c1c' # the commit before f126fe0
def old(bin, path, *flags) = Lab.cli('process', path, *Lab::PROD, *flags, bin: bin)

work = Lab.dir('r')
wav = Lab.programme_wav(File.join(work, 'programme.wav'))
plain = Lab.encode(wav, File.join(work, 'plain.ac3'), codec: 'ac3', dialnorm: -24)
drc = Lab.ac3_with_drc(plain, File.join(work, 'drc.ac3'))
source = Lab.mux(drc, File.join(work, 'source.mkv'))
bins = { unversioned: old_code(UNVERSIONED_SHA), recipe1: old_code(RECIPE1_SHA) }
src = Lab.levels(source)
puts format('source: I %.1f LRA %.1f dialnorm %s (DRC off)', src[:i], src[:lra], Lab.bits_dialnorm(source))

# What each generation leaves in the file.
library = Lab.dir('library')
paths = %w[untouched legacy_stamp recipe1 recipe2 imported].to_h { |name| [name, File.join(library, "#{name}.mkv")] }
paths.each_value { |path| FileUtils.cp(source, path) }
old(bins[:unversioned], paths['legacy_stamp'])
old(bins[:recipe1], paths['recipe1'])
Lab.process(paths['recipe2'])
FileUtils.rm_f(File.join(library, '.neutraliser')) # each file's stamp is what a later run should go on

manifest = File.join(work, 'manifest.jsonl')
File.write(manifest, "#{JSON.generate(file: 'imported.mkv', status: 'done', size: File.size(paths['imported']), mtime: File.mtime(paths['imported']).to_i)}\n")
puts Lab.cli('import-manifest', manifest, '--root', library).first
puts "sidecar recipe for a neutralise.sh file imported today: #{JSON.parse(File.read(File.join(library, '.neutraliser'))).dig('imported.mkv', 'recipe').inspect} (nil = unversioned)"

describe = lambda do |path|
  stamp = Lab.stamp(path)
  out = Lab.levels(path)
  [File.basename(path), stamp&.mode || '-', stamp ? Neutraliser::Recipe.label(stamp.recipe) : '-', stamp&.source_dialnorm || '-',
   Lab.bits_dialnorm(path), Lab.f1(out[:lra]), Lab.f1(out[:i])]
end
Lab.table('What each generation left in the file', %w[file mode recipe stamp_dialnorm stream_dialnorm LRA I], paths.values.map(&describe))

run = lambda do |title, *flags|
  before = paths.transform_values { |path| Lab.sha(path) }
  log, code = Lab.process(library, *flags)
  rows = paths.map do |name, path|
    section = log[/Processing: [^\n]*#{name}\.mkv.*?(?=Processing: |Run summary|\z)/m].to_s
    reason = section[/Peak-limited|Already at target|Replaced|Already processed/] || (log.include?("#{name}.mkv") ? 'seen' : 'skipped at the sidecar/stamp')
    [name, Lab.sha(path) == before[name] ? 'same' : 'CHANGED', reason, *describe.call(path)[1, 4]]
  end
  Lab.table("#{title} (exit #{code})", %w[file bytes what mode recipe stamp_dialnorm stream_dialnorm], rows)
end

run.call('Plain run: only the untouched file should change')
run.call('Second plain run: nothing should change')
puts Lab.cli('report', library).first
run.call('--redo-recipe 1', '--redo-recipe', '1')
run.call('--redo-recipe unversioned', '--redo-recipe', 'unversioned')
run.call('--redo-recipe 1,unversioned again: terminates', '--redo-recipe', '1,unversioned')
puts "\n--redo-recipe 2: #{Lab.process(library, '--redo-recipe', '2').first.lines.last}"

# A redo that does re-encode (here a stricter tolerance forces it), on a file an older recipe damaged: what does the new stamp claim?
launder = File.join(Lab.dir('l'), 'film.mkv')
FileUtils.cp(source, launder)
old(bins[:recipe1], launder, '--target-level', -24)
FileUtils.rm_f(File.join(File.dirname(launder), '.neutraliser'))
before = describe.call(launder)
Lab.process(launder, '--target-level', -21, '--redo-recipe', '1', '--tolerance', '0.5')
Lab.table('Re-encoding a recipe-1 file: the new stamp against the audio', %w[file mode recipe stamp_dialnorm stream_dialnorm LRA I], [before, describe.call(launder)])

# Same question for a compressed or limited file re-levelled to another profile: is the new stamp's `linear` true?
rows = []
{ 'compressed' => ['--lra-target', 8], 'limited' => ['--limit-db', 4] }.each do |name, flags|
  hot = Lab.programme_wav(File.join(Lab.dir('h'), 'hot.wav'), quiet_db: -30, loud_db: -4)
  stream = Lab.encode(hot, File.join(Lab.dir('h'), 's.ac3'), codec: 'ac3', dialnorm: -24, bitrate: '448k')
  file = Lab.mux(stream, File.join(Lab.dir('c'), 'film.mkv'))
  level = Lab.levels(file)
  first_target = (level[:i] + (-1.5 - level[:true_peak]) + 2).round(1)
  Lab.process(file, '--target-level', first_target, '--min-gain', 0, *flags)
  first = Lab.stamp(file)
  now = Lab.levels(file)
  Lab.process(file, '--target-level', (now[:i] - 6).round(1))
  second = Lab.stamp(file)
  rows << [name, first.mode, first.compression, Lab.f1(level[:lra]), Lab.f1(now[:lra]), second.mode, second.compression, Lab.f1(Lab.levels(file)[:lra])]
end
Lab.table('A second run at another target: does the stamp remember?', %w[first_flags first_mode first_rung src_LRA after_LRA second_mode second_rung final_LRA], rows)

# --resume: a manifest says "normalized" from before, then a run asks to redo that recipe or to compress.
resume = Lab.dir('resume')
film = File.join(resume, 'film.mkv')
FileUtils.cp(source, film)
log, = old(bins[:recipe1], resume)
puts "\nrecipe-1 run wrote a manifest entry: #{File.read(File.join(resume, '.neutraliser-run-manifest.jsonl')).lines.last[/"reason":"\w+"/]}"
sha = Lab.sha(film)
log, = Lab.process(resume, '--resume', '--redo-recipe', '1')
puts "--resume --redo-recipe 1: looked at the recipe-1 file? #{log.include?('Processing:')} (#{log[/Resume mode:[^\n]*/]})"
uncompressed = Lab.levels(film)[:lra]
log, = Lab.process(resume, '--resume', '--lra-target', '8')
puts "--resume --lra-target 8 over an uncompressed LRA #{Lab.f1(uncompressed)} file: looked at it? #{log.include?('Processing:')} (#{log[/Resume mode:[^\n]*/]}); bytes #{Lab.sha(film) == sha ? 'same' : 'changed'}, LRA now #{Lab.f1(Lab.levels(film)[:lra])}"
