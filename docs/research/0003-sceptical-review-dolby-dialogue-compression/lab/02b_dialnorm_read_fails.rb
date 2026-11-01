# frozen_string_literal: true

# What happens when the dialnorm read itself fails for a reason that has nothing to do with the file (a full temp
# disk, a slow mount, a killed subprocess)? ffmpeg is wrapped so only that one read fails, and the run goes on.
require_relative 'lab'

work = Lab.dir('fail')
wav = Lab.programme_wav(File.join(work, 'p.wav'), seconds: 30)
stream = Lab.encode(wav, File.join(work, 's.ac3'), codec: 'ac3', dialnorm: -24)
source = Lab.mux(stream, File.join(work, 'source.mkv'))

wrapper_dir = Lab.dir('wrap')
real = `which ffmpeg`.strip
File.write(File.join(wrapper_dir, 'ffmpeg'), <<~SH)
  #!/bin/sh
  case "$*" in
    *head.ac3*|*head.eac3*) echo "No space left on device" >&2; exit 1 ;;
  esac
  exec #{real} "$@"
SH
FileUtils.chmod(0o755, File.join(wrapper_dir, 'ffmpeg'))

file = File.join(Lab.dir('c'), 'film.mkv')
FileUtils.cp(source, file)
before = [Lab.sha(file), Lab.bits_dialnorm(file)]
out, status = Open3.capture2e({ 'PATH' => "#{wrapper_dir}:#{ENV.fetch('PATH')}" }, 'bundle', 'exec', 'ruby', File.join(ROOT, 'bin/neutraliser'),
                              'process', file, *Lab::PROD, chdir: ROOT)
puts "source dialnorm #{before.last}; the read of the first frames fails with 'No space left on device'"
puts "exit #{status.exitstatus}; #{out[/Could not read[^\n]*/] || out[/(FFmpeg error|Error processing file)[^\n]*/]}"
puts "file #{Lab.sha(file) == before.first ? 'untouched' : 'REPLACED'}; dialnorm now #{Lab.bits_dialnorm(file)}; stamp #{Lab.stamp(file)&.mode.inspect}, stamped dialnorm #{Lab.stamp(file)&.source_dialnorm.inspect}"
