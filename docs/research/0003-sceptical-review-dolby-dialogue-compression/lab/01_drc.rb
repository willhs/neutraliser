# frozen_string_literal: true

# Is stream DRC baked in on any path that decodes a Dolby track? A clip whose DRC words squash its loud passages goes
# through every mode, in AC-3 and E-AC-3, and the output's range is compared with the source's with DRC off.
require_relative 'lab'
require File.join(ROOT, 'spec/support/eac3_bits')

work = Lab.dir('drc')
wav = Lab.programme_wav(File.join(work, 'programme.wav'))
ac3_plain = Lab.encode(wav, File.join(work, 'plain.ac3'), codec: 'ac3', dialnorm: -27)
ac3_drc = Lab.ac3_with_drc(ac3_plain, File.join(work, 'drc.ac3'))
eac3_plain = Lab.encode(wav, File.join(work, 'plain.eac3'), codec: 'eac3', dialnorm: -27, extra: ['-channel_coupling', '0'])
eac3_drc = File.join(work, 'drc.eac3')
File.binwrite(eac3_drc, Eac3Bits.add_dynrng(File.binread(eac3_plain)) { |i| ((i * 1536 / 48_000.0) % 20) < 4 ? 0xD3 : 0 })

sources = { 'ac3' => ac3_drc, 'eac3' => eac3_drc }.to_h do |codec, stream|
  mkv = Lab.mux(stream, File.join(work, "#{codec}.mkv"))
  off = Lab.levels(mkv)
  default = Lab.levels(mkv, decoder: [])
  puts format('%-5s source: DRC off I %.1f LRA %.1f | ffmpeg default decode I %.1f LRA %.1f (fixture is real if LRA differs)',
              codec, off[:i], off[:lra], default[:i], default[:lra])
  [codec, { mkv: mkv, off: off }]
end

# Target sits +3 from the DRC-off level, under the peak ceiling, so a constant-gain output should move by 3 and keep the range.
SCENARIOS = {
  'default (driver flags)' => [],
  '--limit-db 4' => ['--limit-db', 4],
  '--lra-target 12' => ['--lra-target', 12],
  '--allow-dynamic' => ['--allow-dynamic'],
  '--fast --allow-dynamic' => ['--fast', '--allow-dynamic'],
  '--local-stage' => ['--local-stage'],
  '--keep-original-audio' => ['--keep-original-audio']
}.freeze

rows = []
sources.each do |codec, source|
  target = (source[:off][:i] + 3).round(1)
  SCENARIOS.each do |name, flags|
    copy = File.join(Lab.dir('s'), 'film.mkv')
    FileUtils.cp(source[:mkv], copy)
    log, code = Lab.process(copy, '--target-level', target, *flags)
    after = Lab.levels(copy)
    stamp = Lab.stamp(copy)
    words = codec == 'ac3' ? Ac3Bits.frames(raw = Lab.raw_stream(copy, 0, 'ac3')).count { |o, s| Ac3Bits.has_dynrng?(raw.byteslice(o, s)) } : '?'
    rows << [codec, name, code, stamp&.mode, Lab.f1(stamp&.measured_lra), Lab.f1(source[:off][:lra]), Lab.f1(after[:lra]),
             Lab.f1(after[:i] - source[:off][:i]), Lab.f1(stamp&.gain_db), words, log[/Could not read[^\n]*/]]
  end
end
Lab.table('DRC through every mode (LRA with DRC off, ebur128)',
          ['codec', 'scenario', 'exit', 'mode', 'stamp LRA', 'src LRA', 'out LRA', 'I moved', 'gain', 'dynrng frames', 'note'], rows)

# The kept original must keep its DRC words and dialnorm: a stream copy, byte for byte.
copy = File.join(Lab.dir('k'), 'film.mkv')
FileUtils.cp(sources['ac3'][:mkv], copy)
before = Digest::SHA256.hexdigest(Lab.raw_stream(copy, 0, 'ac3'))
Lab.process(copy, '--target-level', (sources['ac3'][:off][:i] + 3).round(1), '--keep-original-audio')
puts "\nkept original identical to the source stream: #{Digest::SHA256.hexdigest(Lab.raw_stream(copy, 1, 'ac3')) == before}"

# Primary track on a:1, with a:0 a DRC-free stereo AC-3 that must stay untouched.
dual = File.join(Lab.dir('d'), 'film.mkv')
other = Lab.encode(wav, File.join(work, 'other.ac3'), codec: 'ac3', dialnorm: -20)
Lab.ffmpeg('-i', sources['ac3'][:mkv], '-i', other, '-map', '0:v', '-map', '1:a', '-map', '0:a', '-c', 'copy',
           '-disposition:a:0', '0', '-disposition:a:1', 'default', dual)
src = Lab.levels(dual, index: 1)
Lab.process(dual, '--target-level', (src[:i] + 3).round(1))
out = Lab.levels(dual, index: 1)
puts format('primary on a:1: LRA %.1f -> %.1f, I moved %.1f, stamp %s, a:1 dialnorm %s, a:0 dialnorm %s',
            src[:lra], out[:lra], out[:i] - src[:i], Lab.stamp(dual)&.mode, Lab.bits_dialnorm(dual, index: 1), Lab.bits_dialnorm(dual, index: 0))

# Every ffmpeg command line a real run builds, read back from a logging wrapper: does each one that decodes carry the flag?
wrapper_dir = Lab.dir('wrap')
log_file = File.join(wrapper_dir, 'commands.log')
real = `which ffmpeg`.strip
File.write(File.join(wrapper_dir, 'ffmpeg'), "#!/bin/sh\necho \"$*\" >> #{log_file}\nexec #{real} \"$@\"\n")
FileUtils.chmod(0o755, File.join(wrapper_dir, 'ffmpeg'))
copy = File.join(Lab.dir('w'), 'film.mkv')
FileUtils.cp(sources['ac3'][:mkv], copy)
env = { 'PATH' => "#{wrapper_dir}:#{ENV.fetch('PATH')}" }
bin = File.join(ROOT, 'bin/neutraliser')
Open3.capture2e(env, 'bundle', 'exec', 'ruby', bin, 'process', copy, *Lab::PROD, '--lra-target', '12', chdir: ROOT)
Open3.capture2e(env, 'bundle', 'exec', 'ruby', bin, 'report', copy, '--measure', chdir: ROOT)
commands = File.readlines(log_file).reject { |line| line.start_with?('-version') }
decoding = commands.grep_v(/-c copy|-c:a copy$/)
puts "\nffmpeg commands in process + report --measure: #{commands.size}; decoding ones missing -drc_scale 0: " \
     "#{decoding.reject { |line| line.include?('-drc_scale 0') }.size}"
decoding.reject { |line| line.include?('-drc_scale 0') }.each { |line| puts "  MISSING: #{line[0, 160]}" }
