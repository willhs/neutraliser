# frozen_string_literal: true

# Is dialnorm right after every re-encode? Two independent reads: the bitstream (DolbyStream) and the gain ffmpeg's
# decoder applies when told to honour it (-target_level -31).
require_relative 'lab'

work = Lab.dir('dn')

# The reader, on every channel layout the AC-3 header treats differently (optional mix-level fields shift dialnorm).
rows = []
%w[mono stereo 3.0 3.0(back) 4.0 quad 2.1 5.0 5.1 5.1(side)].each do |layout|
  %w[ac3 eac3].each do |codec|
    wav = Lab.surround_wav(File.join(Lab.dir('w'), 'a.wav'), layout, seconds: 8)
    stream = Lab.encode(wav, File.join(work, "#{codec}-#{layout}.#{codec}"), codec: codec, dialnorm: -24, bitrate: '448k')
    mkv = Lab.mux(stream, File.join(work, "#{codec}-#{layout}.mkv"))
    rows << [layout, codec, Lab.stream_info(mkv)['channel_layout'], Neutraliser::DolbyStream.dialnorm(File.binread(stream)), Lab.heard_dialnorm(mkv)]
  rescue StandardError => e
    rows << [layout, codec, 'encoder refused', e.message.lines.last.to_s.strip[0, 50], '']
  end
end
Lab.table('Reader vs decoder: source dialnorm -24', %w[asked codec layout bits heard], rows)

# Through each mode, stereo and 5.1. The clip is hot enough that --limit-db really limits and quiet enough to need gain.
hot = Lab.programme_wav(File.join(work, 'hot.wav'), quiet_db: -30, loud_db: -4)
hot51 = File.join(work, 'hot51.wav')
Lab.ffmpeg('-i', hot, '-af', 'pan=5.1(side)|c0=c0|c1=c1|c2=c0|c3=c0|c4=c0|c5=c1', '-c:a', 'pcm_s24le', hot51)
rows = []
{ 'stereo' => hot, '5.1' => hot51 }.each do |shape, wav|
  %w[ac3 eac3].each do |codec|
    stream = Lab.encode(wav, File.join(Lab.dir('e'), "s.#{codec}"), codec: codec, dialnorm: -27, bitrate: '448k')
    source = Lab.mux(stream, File.join(Lab.dir('m'), 'film.mkv'))
    src = Lab.levels(source)
    # A target 2 dB past what the peak ceiling allows: constant gain stops at the ceiling and --limit-db really limits.
    target = (src[:i] + (-1.5 - src[:true_peak]) + 2).round(1)
    { 'default' => [], '--limit-db 4' => ['--limit-db', 4], '--lra-target 3' => ['--lra-target', 3],
      '--lra-target 3 --limit-db 4' => ['--lra-target', 3, '--limit-db', 4], '--fast' => ['--fast', '--allow-dynamic'],
      '--keep-original-audio' => ['--keep-original-audio'] }.each do |name, flags|
      copy = File.join(Lab.dir('c'), 'film.mkv')
      FileUtils.cp(source, copy)
      log, code = Lab.process(copy, '--target-level', target, '--min-gain', 0, *flags)
      stamp = Lab.stamp(copy)
      kept = flags.include?('--keep-original-audio') ? Lab.bits_dialnorm(copy, index: 1, codec: codec) : ''
      rows << [shape, codec, name, code, stamp&.mode, stamp&.compression, Lab.bits_dialnorm(copy, codec: codec), Lab.heard_dialnorm(copy),
               stamp&.source_dialnorm, kept, Lab.f1(stamp&.gain_db), log[/Peak-limited/]]
    end
  end
end
Lab.table('Dialnorm through each mode: source -27', %w[shape codec mode exit stamped compression bits heard stamp kept gain note], rows)

# A second generation must keep the first source's value, and two runs must agree.
stream = Lab.encode(hot, File.join(Lab.dir('e'), 's.ac3'), codec: 'ac3', dialnorm: -22)
file = Lab.mux(stream, File.join(Lab.dir('g'), 'film.mkv'))
level = Lab.levels(file)[:i]
Lab.process(file, '--target-level', (level + 3).round(1))
first = [Lab.bits_dialnorm(file), Lab.stamp(file).source_dialnorm]
Lab.process(file, '--target-level', (level + 6).round(1), '--min-gain', 0)
puts "\nSecond generation (source -22): after first #{first}, after second #{[Lab.bits_dialnorm(file), Lab.stamp(file).source_dialnorm]}"

# Containers: the read is a raw copy of the first frames; do they start on a sync word in each one?
rows = []
{ '.mkv' => 'ac3', '.mp4' => 'ac3', '.mov' => 'ac3', '.avi' => 'ac3', '.m4v' => 'ac3', '.flv' => nil }.each do |ext, codec|
  next unless codec

  stream = Lab.encode(hot, File.join(Lab.dir('e'), 's.ac3'), codec: codec, dialnorm: -26)
  path = File.join(Lab.dir('x'), "film#{ext}")
  begin
    Lab.mux(stream, path, extra: ext == '.avi' ? [] : [])
  rescue StandardError => e
    rows << [ext, 'mux refused', e.message.lines.last.to_s.strip[0, 40], '', '']
    next
  end
  track = Neutraliser::Source.new(path).audio_tracks.first
  read = begin
    Neutraliser::FFmpegWrapper.read_dialnorm(path, track)
  rescue StandardError => e
    "FAIL #{e.message[0, 50]}"
  end
  level = Lab.levels(path)[:i]
  log, code = Lab.process(path, '--target-level', (level + 3).round(1))
  out = Lab.stream_info(path)
  rows << [ext, read, code, out['codec_name'], (Lab.bits_dialnorm(path) rescue 'unreadable'), Lab.stamp(path)&.source_dialnorm, log[/Could not read[^\n]*/]]
end
Lab.table('Reading dialnorm per container: source -26', %w[container read exit out_codec out_bits stamp note], rows)

# Dialnorm that changes partway: the reader sees the first frame only.
a = Lab.encode(hot, File.join(work, 'a.ac3'), codec: 'ac3', dialnorm: -24)
b = Lab.encode(hot, File.join(work, 'b.ac3'), codec: 'ac3', dialnorm: -31)
joined = File.join(work, 'joined.ac3')
File.binwrite(joined, File.binread(a) + File.binread(b))
file = Lab.mux(joined, File.join(Lab.dir('j'), 'film.mkv'))
before = Neutraliser::DolbyStream.dialnorm(File.binread(joined))
tail = Lab.ffmpeg('-sseof', '-10', '-i', file, '-map', '0:a', '-c', 'copy', '-f', 'ac3', File.join(work, 'tail.ac3')) && Neutraliser::DolbyStream.dialnorm(File.binread(File.join(work, 'tail.ac3')))
level = Lab.levels(file)[:i]
Lab.process(file, '--target-level', (level + 3).round(1))
Lab.ffmpeg('-sseof', '-10', '-i', file, '-map', '0:a', '-c', 'copy', '-f', 'ac3', File.join(work, 'tail2.ac3'))
puts "\nDialnorm that changes partway: head #{before}, tail #{tail}; after the run head #{Lab.bits_dialnorm(file)}, " \
     "tail #{Neutraliser::DolbyStream.dialnorm(File.binread(File.join(work, 'tail2.ac3')))}"
