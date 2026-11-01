# frozen_string_literal: true

# --centre-boost and the dialogue estimate on layouts other than 5.1. Each channel gets its own level, so the output
# shows which channel moved and the estimate shows which channel it read. Then: can the boost clip before the
# compressor, on sample formats pan doesn't process in float?
require_relative 'lab'

include Neutraliser # rubocop:disable Style/MixinUsage

# Channel names by position, for the layouts this tries.
NAMES = {
  'mono' => %w[FC], 'stereo' => %w[FL FR], '2.1' => %w[FL FR LFE], '3.0' => %w[FL FR FC], '3.0(back)' => %w[FL FR BC],
  '4.0' => %w[FL FR FC BC], 'quad' => %w[FL FR BL BR], 'quad(side)' => %w[FL FR SL SR], '3.1' => %w[FL FR FC LFE],
  '5.0' => %w[FL FR FC BL BR], '5.0(side)' => %w[FL FR FC SL SR], '4.1' => %w[FL FR FC LFE BC],
  '5.1' => %w[FL FR FC LFE BL BR], '5.1(side)' => %w[FL FR FC LFE SL SR], '6.0' => %w[FL FR FC BC SL SR],
  '6.0(front)' => %w[FL FR FLC FRC SL SR], 'hexagonal' => %w[FL FR FC BL BR BC], '6.1' => %w[FL FR FC LFE BC SL SR],
  '6.1(front)' => %w[FL FR LFE FLC FRC SL SR], '7.0' => %w[FL FR FC BL BR SL SR], '7.0(front)' => %w[FL FR FC FLC FRC SL SR],
  '7.1' => %w[FL FR FC LFE BL BR SL SR], '7.1(wide)' => %w[FL FR FC LFE BL BR FLC FRC]
}.freeze

# Wide-range programme with each channel 2 dB further down than the last, in .mov PCM: it stores the layout.
def layered(layout, dir)
  count = Lab.channels(layout)
  wav = Lab.programme_wav(File.join(dir, 'p.wav'), seconds: 24, quiet_db: -36, loud_db: -16)
  pan = (0...count).map { |c| "c#{c}=#{format('%.4f', 10**(-2 * c / 20.0))}*c0" }.join('|')
  file = File.join(dir, 'film.mov')
  Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=24', '-i', wav, '-filter_complex', "[1:a]pan=#{layout}|#{pan}[a]",
             '-map', '0:v', '-map', '[a]', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'pcm_s24le', '-shortest', file)
  file
end

def channel_rms(path, count)
  (0...count).map do |c|
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', *Lab::NO_DRC, '-i', path, '-map', '0:a:0', '-af', "pan=mono|c0=c#{c},astats=measure_overall=RMS_level:measure_perchannel=0", '-f', 'null', '-')
    out[/RMS level dB:\s+(-?[\d.]+|-inf)/, 1].to_f
  end
end

rows = []
NAMES.each do |layout, names|
  dir = Lab.dir('l')
  file = layered(layout, dir)
  info = Lab.stream_info(file)
  track = Neutraliser::Source.new(file).primary_track
  estimate = DialogueMeter.estimate(file, track)
  truth = names.index('FC') && Lab.levels(file, filter: "pan=mono|c0=c#{names.index('FC')}")[:i]
  read_channel = if estimate.available?
                   by_channel = (0...names.size).map { |c| [names[c], (Lab.levels(file, filter: "pan=mono|c0=c#{c}")[:i] - estimate.level).abs] }
                   by_channel.min_by(&:last).first
                 end
  before = channel_rms(file, names.size)
  copy = File.join(Lab.dir('c'), 'film.mov')
  FileUtils.cp(file, copy)
  log, code = Lab.process(copy, '--lra-target', 6, '--centre-boost', 6)
  after = channel_rms(copy, names.size)
  relative = before.zip(after).map { |x, y| y - x }
  moved = names.zip(relative).select { |_, d| (d - relative.min).abs > 1.5 }.map(&:first)
  stamp = Lab.stamp(copy)
  rows << [layout, info['channel_layout'], Lab.stream_info(copy)['channel_layout'], code, stamp&.mode, Lab.f1(stamp&.centre_boost_db), moved.join(','),
           log[/--centre-boost skipped/] ? 'noted' : '',
           estimate.available? ? "reads #{read_channel}" : "none (#{estimate.reason[0, 26]})", if estimate.available?
             read_channel == 'FC' ? 'right' : "WRONG: #{truth ? 'not FC' : 'no FC'}"
           else
             layout == 'mono' || truth.nil? ? 'right' : 'WRONG: has FC'
           end]
rescue StandardError => e
  rows << [layout, "error: #{e.message.lines.last.to_s.strip[0, 80]}"]
end
Lab.table('Boost and estimate by layout (PCM in .mov)', %w[asked probed output exit mode boost channel_moved_vs_rest skip_note estimate estimate_verdict], rows)

# Does pan clip? Centre peaks near full scale with +6 dB. In integer samples nothing can leave pan above 0 dBFS, so read
# the centre straight after pan, on its own, and through the real chain (pan then the gentle rung).
dir = Lab.dir('clip')
hot = File.join(dir, 'hot.wav')
Lab.ffmpeg('-f', 'lavfi', '-i', 'anoisesrc=color=pink:sample_rate=48000:seed=3:duration=10',
           '-af', 'volume=8dB,alimiter=limit=0.7:level=0,pan=5.1|c0=0.1*c0|c1=0.1*c0|c2=c0|c3=0.1*c0|c4=0.1*c0|c5=0.1*c0', '-c:a', 'pcm_f32le', hot)
rung = Compression::LADDER.first.filter(-20.0)
peak = ->(path) { 20 * Math.log10(File.binread(path).unpack('E*').map(&:abs).max) }
read_centre = lambda do |file, chain|
  raw = File.join(Lab.dir('r'), 'c.f64')
  Lab.ffmpeg(*Lab::NO_DRC, '-i', file, '-map', '0:a:0', '-af', "#{chain}pan=mono|c0=c2", '-f', 'f64le', '-acodec', 'pcm_f64le', raw)
  peak.call(raw)
end
rows = []
{ 'wav f32 (reference, float all the way)' => [hot, nil], 'flac s16' => ['.mkv', ['-c:a', 'flac', '-sample_fmt', 's16']], 'flac s24' => ['.mkv', ['-c:a', 'flac', '-sample_fmt', 's32']],
  'ac3' => ['.mkv', ['-c:a', 'ac3', '-b:a', '640k']], 'eac3' => ['.mkv', ['-c:a', 'eac3', '-b:a', '640k']], 'aac' => ['.mp4', ['-c:a', 'aac', '-b:a', '512k']],
  'truehd' => ['.mkv', ['-strict', '-2', '-c:a', 'truehd']], 'dts' => ['.mkv', ['-strict', '-2', '-c:a', 'dca', '-b:a', '1509k']] }.each do |name, (ext, opts)|
  file = opts ? File.join(Lab.dir('f'), "film#{ext}") : ext
  Lab.ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=10', '-i', hot, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'ultrafast', *opts, '-shortest', file) if opts
  layout = Lab.stream_info(file)['channel_layout']
  track = Neutraliser::Source.new(file).primary_track
  track = track.merge(channel_layout: '5.1') unless Compression.centre_channel?(track)
  boost = Compression.centre_boost_filter(track, 6.0)
  rows << [name, layout, Lab.f1(read_centre.call(file, '')), Lab.f1(read_centre.call(file, "#{boost},")), Lab.f1(read_centre.call(file, "#{boost},#{rung},"))]
rescue StandardError => e
  rows << [name, "error: #{e.message.lines.last.to_s.strip[0, 80]}"]
end
Lab.table('Centre peak: source, after +6 dB pan alone, after pan and the gentle rung (dBFS)', %w[source layout source_peak after_pan after_chain], rows)
