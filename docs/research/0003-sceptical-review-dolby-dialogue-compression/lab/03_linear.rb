# frozen_string_literal: true

# Is a stamped `linear` really one gain? A lossless source through a lossless output lets the whole file be nulled
# against source * gain, sample by sample, which no lossy path allows.
require_relative 'lab'

def samples(path, index: 0)
  raw = File.join(Lab.dir('raw'), 'a.f64')
  Lab.ffmpeg('-i', path, '-map', "0:a:#{index}", '-f', 'f64le', '-acodec', 'pcm_f64le', raw)
  File.binread(raw).unpack('E*')
end

def null_test(source, output, gain_db)
  gain = 10**(gain_db / 20.0)
  a = samples(source)
  b = samples(output)
  residual = a.zip(b).map { |x, y| y.nil? ? 1.0 : (y - x * gain).abs }.max
  [a.size == b.size, residual.zero? ? -999.0 : 20 * Math.log10(residual)]
end

work = Lab.dir('lin')
wide = Lab.programme_wav(File.join(work, 'wide.wav'), seconds: 40)
steady = Lab.surround_wav(File.join(work, 'steady.wav'), 'stereo', seconds: 30, db: -26)
sources = {
  'flac s16, wide LRA' => ['-c:a', 'flac', '-sample_fmt', 's16', wide],
  'flac s24, wide LRA' => ['-c:a', 'flac', '-sample_fmt', 's32', wide],
  'flac s24, steady' => ['-c:a', 'flac', '-sample_fmt', 's32', steady]
}
rows = []
sources.each do |name, (c, codec, s, fmt, wav)|
  path = File.join(Lab.dir('s'), 'film.mkv')
  Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=40', '-i', wav, '-map', '0:v', '-map', '1:a',
             '-c:v', 'libx264', '-preset', 'ultrafast', c, codec, s, fmt, '-shortest', path)
  level = Lab.levels(path)[:i]
  { 'default' => [], '--allow-dynamic' => ['--allow-dynamic'] }.each do |mode, flags|
    copy = File.join(Lab.dir('c'), 'film.mkv')
    FileUtils.cp(path, copy)
    log, code = Lab.process(copy, '--target-level', (level + 3).round(1), *flags)
    stamp = Lab.stamp(copy)
    same, residual = stamp&.gain_db ? null_test(path, copy, stamp.gain_db) : [nil, nil]
    info = Lab.stream_info(copy)
    rows << [name, mode, code, stamp&.mode, stamp&.gain_db, log[/Normalization: \w+/], same, Lab.f1(residual),
             "#{info['codec_name']}/#{info['sample_fmt']}/#{info['bits_per_raw_sample']}"]
  end
end
Lab.table('Null test: output minus source * stamped gain (peak residual, dBFS)',
          ['source', 'mode', 'exit', 'stamp', 'gain', 'log', 'same length', 'residual', 'output'], rows)

# Each stamp's mode against what the filter chain contains, read from the real ffmpeg command line.
wrapper_dir = Lab.dir('wrap')
log_file = File.join(wrapper_dir, 'commands.log')
real = `which ffmpeg`.strip
File.write(File.join(wrapper_dir, 'ffmpeg'), "#!/bin/sh\necho \"$*\" >> #{log_file}\nexec #{real} \"$@\"\n")
FileUtils.chmod(0o755, File.join(wrapper_dir, 'ffmpeg'))
env = { 'PATH' => "#{wrapper_dir}:#{ENV.fetch('PATH')}" }
hot = Lab.programme_wav(File.join(work, 'hot.wav'), quiet_db: -30, loud_db: -4)
stream = Lab.encode(hot, File.join(work, 's.ac3'), codec: 'ac3', dialnorm: -27, bitrate: '448k')
source = Lab.mux(stream, File.join(work, 'source.mkv'))
measured = Lab.levels(source)
level = measured[:i]
headroom = -1.5 - measured[:true_peak]
rows = []
{ 'gain under ceiling' => [(level + 1).round(1), []],
  'gain over ceiling, no limiter' => [(level + headroom + 3).round(1), []],
  'gain within --limit-db reach, no overshoot' => [(level + 1).round(1), ['--limit-db', 4]],
  'gain needs --limit-db' => [(level + headroom + 3).round(1), ['--limit-db', 4]],
  '--lra-target' => [(level + 1).round(1), ['--lra-target', 6]],
  '--lra-target --limit-db' => [(level + headroom + 3).round(1), ['--lra-target', 6, '--limit-db', 8]] }.each do |name, (target, flags)|
  FileUtils.rm_f(log_file)
  copy = File.join(Lab.dir('c'), 'film.mkv')
  FileUtils.cp(source, copy)
  Open3.capture2e(env, 'bundle', 'exec', 'ruby', File.join(ROOT, 'bin/neutraliser'), 'process', copy, *Lab::PROD, '--min-gain', '0', '--tolerance', '0.5',
                  '--target-level', target.to_s, *flags.map(&:to_s), chdir: ROOT)
  encode = File.exist?(log_file) ? File.readlines(log_file).find { |line| line.include?('[norm]') } : nil
  chain = encode.to_s[/\[0:a:\d+\](.*?)\[norm\]/, 1].to_s
  filters = chain.split(',').map { |f| f[/\A\w+/] }
  rows << [name, Lab.stamp(copy)&.mode, Lab.stamp(copy)&.compression, filters.join(' ')]
end
Lab.table('Stamped mode against the filter chain', %w[case mode compression filters], rows)
