# frozen_string_literal: true

# Two things a sweep restart hits that no code on main can fix by itself. 1: the driver runs `docker run IMAGE:latest`
# and never pulls, so it runs whatever image the host last pulled. Run an out-of-date image on the DRC clip. 2: a file
# an earlier run left alone as "within tolerance" was judged with DRC on, and its sidecar entry still says done.
require_relative 'lab'

def old_code(sha)
  dir = Lab.dir("old-#{sha}")
  Lab.run!('sh', '-c', "git -C #{ROOT} archive #{sha} lib bin | tar -x -C #{dir}")
  File.join(dir, 'bin/neutraliser')
end

work = Lab.dir('restart')
wav = Lab.programme_wav(File.join(work, 'programme.wav'))
plain = Lab.encode(wav, File.join(work, 'plain.ac3'), codec: 'ac3', dialnorm: -24)
drc = Lab.ac3_with_drc(plain, File.join(work, 'drc.ac3'))
source = Lab.mux(drc, File.join(work, 'source.mkv'))
src = Lab.levels(source)
default = Lab.levels(source, decoder: [])
puts format('source: DRC off I %.1f LRA %.1f, dialnorm %s; as a DRC-on decode reads it I %.1f LRA %.1f', src[:i], src[:lra], Lab.bits_dialnorm(source), default[:i], default[:lra])

# 1. The same clip through a pre-fix image and through this tree in the same image.
stale_image = ENV.fetch('LAB_STALE_IMAGE', 'ghcr.io/willhs/neutraliser:latest')
fresh_image = ENV.fetch('LAB_FRESH_IMAGE', 'neutraliser-retest:latest')
has_fix = Open3.capture2e('docker', 'run', '--rm', '--entrypoint', 'sh', stale_image, '-c', 'ls /app/lib/neutraliser/dolby_stream.rb').first
created = Lab.run!('docker', 'image', 'inspect', '--format', '{{.Created}}', stale_image).strip
puts "\nImage under test #{stale_image}, built #{created}: #{has_fix.include?('No such file') ? 'has no dolby_stream.rb' : 'has dolby_stream.rb'}"
rows = []
{ 'image as last pulled' => [stale_image, []], 'same base, this tree mounted' => [fresh_image, ['-v', "#{ROOT}/lib:/app/lib:ro"]] }.each do |name, (image, mounts)|
  file = File.join(Lab.dir('s'), 'film.mkv')
  FileUtils.cp(source, file)
  out, status = Open3.capture2e('docker', 'run', '--rm', '-v', "#{Lab.tmp}:#{Lab.tmp}", '-v', "#{Lab.dir('ctmp')}:/tmp", *mounts, image, 'process', file, *Lab::PROD)
  after = Lab.levels(file)
  stamp = Lab.stamp(file)
  rows << [name, status.exitstatus, stamp&.mode, stamp ? Neutraliser::Recipe.label(stamp.recipe) : '-', Lab.f1(after[:lra]), Lab.f1(after[:i]), Lab.bits_dialnorm(file), out[/ffmpeg version[^\n]*/]]
end
Lab.table('The driver flags over the DRC clip: source LRA 20, dialnorm -24', %w[run exit mode recipe out_LRA out_I dialnorm note], rows)

# 2. A verdict from before the fix. Choose the target so a DRC-on reading lands inside the tolerance and the truth doesn't.
library = Lab.dir('verdict')
file = File.join(library, 'film.mkv')
FileUtils.cp(source, file)
target = default[:i].round(1)
bins = old_code('5b82c1c')
Lab.cli('process', file, '--replace', '--tolerance', 2, '--min-gain', 1, '--no-fast-verify', '--no-cache', '--target-level', target, bin: bins)
entry = JSON.parse(File.read(File.join(library, '.neutraliser'))).fetch('film.mkv')
sha = Lab.sha(file)
puts "\nTarget #{target}: recipe 1 read the clip with DRC on and left it, sidecar #{entry.slice('recipe', 'tolerance', 'profile')}. The truth is #{format('%.1f', src[:i])}, #{format('%.1f', src[:i] - target)} LU away."
log, = Lab.process(file, '--target-level', target)
puts "Restart, driver flags: bytes #{Lab.sha(file) == sha ? 'same' : 'CHANGED'}: #{log[/Already processed|Replaced/]}"
log, = Lab.process(file, '--target-level', target, '--redo-recipe', '1')
after = Lab.levels(file)
puts format('Restart with --redo-recipe 1: %s, %s, now I %.1f LRA %.1f dialnorm %s, stamp %s', Lab.sha(file) == sha ? 'bytes same' : 'bytes changed', log[/Replaced|Peak-limited|Already at target/], after[:i], after[:lra], Lab.bits_dialnorm(file), Lab.stamp(file)&.mode)
