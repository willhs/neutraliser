# frozen_string_literal: true

# Will's planned flags, --allow-codec-change and --allow-object-audio-loss, with the driver's flags, on real DTS,
# TrueHD and an E-AC-3 stream a real ffmpeg decoder reports as Atmos. Do they work with the Dolby fixes and the stamps?
require_relative 'lab'
require File.join(ROOT, 'spec/support/eac3_bits')

include Neutraliser # rubocop:disable Style/MixinUsage

BOTH = %w[--allow-codec-change --allow-object-audio-loss].freeze

work = Lab.dir('flags')
stereo = Lab.programme_wav(File.join(work, 'stereo.wav'), seconds: 30, quiet_db: -36, loud_db: -16)
surround = File.join(work, 'surround.wav')
Lab.ffmpeg('-i', stereo, '-af', 'pan=5.1(side)|c0=c0|c1=c1|c2=c0|c3=0.2*c0|c4=c0|c5=c1', '-c:a', 'pcm_s24le', surround)
seven = File.join(work, 'seven.wav')
Lab.ffmpeg('-i', stereo, '-af', 'pan=7.1|c0=c0|c1=c1|c2=c0|c3=0.2*c0|c4=c0|c5=c1|c6=c0|c7=c1', '-c:a', 'pcm_s24le', seven)

def wrap(wav, ext, *opts)
  out = File.join(Lab.dir('s'), "film#{ext}")
  Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=30', '-i', wav, '-map', '0:v', '-map', '1:a',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-strict', '-2', *opts, '-shortest', out)
  out
end

eac3_plain = Lab.encode(surround, File.join(work, 'plain.eac3'), codec: 'eac3', dialnorm: -27, bitrate: '640k', extra: ['-channel_coupling', '0'])
atmos_stream = File.join(work, 'atmos.eac3')
File.binwrite(atmos_stream, Eac3Bits.add_atmos_flag(File.binread(eac3_plain)))

sources = {
  'DTS 5.1 .mkv' => [wrap(surround, '.mkv', '-c:a', 'dca', '-b:a', '1509k'), BOTH],
  'DTS stereo .mkv' => [wrap(stereo, '.mkv', '-c:a', 'dca', '-b:a', '768k'), BOTH],
  'TrueHD 5.1 .mkv' => [wrap(surround, '.mkv', '-c:a', 'truehd'), BOTH],
  'PCM 7.1 .mov' => [wrap(seven, '.mov', '-c:a', 'pcm_s24le'), BOTH],
  'TrueHD 5.1 .mp4' => [wrap(surround, '.mp4', '-c:a', 'truehd'), BOTH],
  'FLAC 7.1 .mp4 (to E-AC-3)' => [wrap(seven, '.mp4', '-c:a', 'flac'), BOTH],
  'DTS 5.1 .mp4' => [wrap(surround, '.mp4', '-c:a', 'dca', '-b:a', '1509k'), BOTH],
  'E-AC-3 Atmos .mkv' => [Lab.mux(atmos_stream, File.join(Lab.dir('a'), 'film.mkv')), BOTH],
  'E-AC-3 Atmos .mp4' => [Lab.mux(atmos_stream, File.join(Lab.dir('a'), 'film.mp4')), BOTH],
  'E-AC-3 Atmos, no flags' => [Lab.mux(atmos_stream, File.join(Lab.dir('a'), 'film.mkv')), []],
  'DTS 5.1, no flags' => [wrap(surround, '.mkv', '-c:a', 'dca', '-b:a', '1509k'), []]
}

rows = []
sources.each do |name, (file, flags)|
  before = Lab.stream_info(file)
  src = Lab.levels(file)
  copy = File.join(Lab.dir('c'), File.basename(file))
  FileUtils.cp(file, copy)
  log, code = Lab.process(copy, *flags)
  after = Lab.stream_info(copy)
  out = Lab.levels(copy)
  stamp = Lab.stamp(copy)
  note = log[/Warning: primary track[^(\n]*/] || log[/(Output does not match[^\n]*|FFmpeg error[^\n]*|Codec change[^,\n]*|Object audio[^:\n]*)/]
  rerun, = Lab.process(copy, *flags)
  rows << [name, "#{before['codec_name']}/#{before['profile']&.slice(0, 22)}/#{before['channel_layout']}", code,
           "#{after['codec_name']}/#{after['channel_layout']}/#{after['bits_per_raw_sample']}", stamp&.mode, stamp&.source_codec,
           stamp&.source_dialnorm, Lab.f1(src[:lra]), Lab.f1(out[:lra]), Lab.f1(out[:i]), rerun.include?('Already processed') ? 'skip' : 'looked again', note.to_s[0, 58]]
rescue StandardError => e
  rows << [name, "error: #{e.message.lines.first(2).join(' ').strip[0, 150]}"]
end
Lab.table('Planned flags, driver flags (target -20)', %w[source probed exit output mode stamp_codec dialnorm src_LRA out_LRA out_I rerun note], rows)

# After a flatten, what can a later reader learn? The stamp and report on an Atmos file processed with the flag.
copy = File.join(Lab.dir('c'), 'film.mkv')
FileUtils.cp(sources['E-AC-3 Atmos .mkv'].first, copy)
Lab.process(copy, *BOTH)
tags = JSON.parse(Lab.run!('ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream_tags', '-of', 'json', copy))['streams'][0]['tags'].select { |key, _| key.upcase.start_with?('NEUTRALISER') }
puts "\nAfter flattening Atmos, does anything say it was Atmos? profile now: #{Lab.stream_info(copy)['profile'].inspect}; tags mentioning it: #{tags.select { |_, value| value =~ /atmos/i }.inspect}"
puts "stamp tags: #{tags.keys.map { |k| k.sub(/\ANEUTRALISER_/i, '') }.join(' ')}"

# Within tolerance and peak-capped with the flags: objects must survive (no re-encode), which is the point of leaving it.
level = Lab.levels(sources['E-AC-3 Atmos .mkv'].first)[:i]
copy = File.join(Lab.dir('c'), 'film.mkv')
FileUtils.cp(sources['E-AC-3 Atmos .mkv'].first, copy)
sha = Lab.sha(copy)
log, = Lab.process(copy, *BOTH, '--target-level', level.round(1))
puts "Atmos already within tolerance, flags on: bytes #{Lab.sha(copy) == sha ? 'same' : 'CHANGED'}, profile #{Lab.stream_info(copy)['profile'].inspect}"

# A sweep restart over what the flags newly reach: a left-alone record for the same file must give way.
copy = File.join(Lab.dir('c'), 'film.mkv')
FileUtils.cp(sources['DTS 5.1, no flags'].first, copy)
Lab.process(copy)
record = SkipDecider.left_record_for(copy)
Lab.process(copy, *BOTH)
puts "DTS left-alone record #{record&.reason.inspect}, then with the flag: stamp #{Lab.stamp(copy)&.mode.inspect}, record now #{SkipDecider.left_record_for(copy)&.reason.inspect}"

# How much bigger does a codec change make the file? It decides the disk floors.
rows = sources.select { |name, (_, flags)| flags == BOTH && name.start_with?('DTS', 'TrueHD') }.map do |name, (file, _)|
  copy = File.join(Lab.dir('c'), File.basename(file))
  FileUtils.cp(file, copy)
  Lab.process(copy, *BOTH)
  [name, File.size(file) / 1024, File.size(copy) / 1024, format('%.2f', File.size(copy).fdiv(File.size(file)))]
end
Lab.table('Size on a 30 s clip (audio only matters here)', %w[source before_kib after_kib ratio], rows)

# A/V sync: the first audio packet's time before and after, on a track that starts late and on one that starts on time.
first_audio = lambda do |path|
  out = Lab.run!('ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'packet=pts_time', '-read_intervals', '%+#1', '-of', 'csv=p=0', path)
  out.lines.first.to_s.delete(',').strip.to_f
end
rows = []
{ 'AC-3' => [['-c:a', 'ac3', '-b:a', '448k'], 'ac3'], 'E-AC-3' => [['-c:a', 'eac3', '-b:a', '448k'], 'eac3'], 'DTS' => [['-strict', '-2', '-c:a', 'dca', '-b:a', '1509k'], 'dts'],
  'TrueHD' => [['-strict', '-2', '-c:a', 'truehd'], 'truehd'], 'FLAC' => [['-c:a', 'flac'], 'flac'] }.each do |name, (opts, _)|
  [0.0, 0.5].each do |delay|
    audio = File.join(Lab.dir('a'), 'a.mka')
    Lab.ffmpeg('-i', surround, *opts, audio)
    file = File.join(Lab.dir('s'), 'film.mkv')
    Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=30', '-itsoffset', delay, '-i', audio, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'copy', file)
    before = first_audio.call(file)
    _, code = Lab.process(file, *BOTH)
    rows << [name, delay, code, Lab.stream_info(file)['codec_name'], format('%.3f', before), format('%.3f', first_audio.call(file))]
  end
rescue StandardError => e
  rows << [name, "error: #{e.message.lines.first(2).join(' ').strip[0, 120]}"]
end
Lab.table('First audio packet time, seconds', %w[source delay exit output before after], rows)
