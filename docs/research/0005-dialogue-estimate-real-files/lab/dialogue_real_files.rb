# Research 0005: measure the dialogue estimate on real library files, read-only, Plex-idle-gated.
#
#   ruby dialogue_real_files.rb plan      # pick the sample -> DATA/plan.json
#   ruby dialogue_real_files.rb run [UNTIL_HHMM]   # measure each planned file -> DATA/results.jsonl
#
# Each file is read once over Plex's own part URL (the primary audio track and one English text subtitle
# are stream-copied into a scratch folder), then everything else runs on that local copy with the
# project's own DialogueMeter / FFmpegWrapper code. Nothing is written to the library. Scratch is deleted.
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'time'
require_relative '../../../../lib/neutraliser'
require_relative 'plex_probe'

DATA = File.expand_path('../data', __dir__)
PLAN = File.join(DATA, 'plan.json')
RUN_PLAN = ENV['PLAN_FILE'] || PLAN # plan2.json for the extra screened files
RESULTS = File.join(DATA, 'results.jsonl')
SEED = 20_261_116
MAX_BYTES = 22 * 1024**3
POLL_S = 60

# Sample design: dialnorm ground truth only exists on AC-3 / E-AC-3, so those are over-sampled; other
# 5.1 codecs and stereo are in for the step-3 counts. (kind, group, how many)
STRATA = [
  ['movie', :dolby51, 14], ['movie', :other51, 4], ['movie', :stereo, 4],
  ['episode', :dolby51, 12], ['episode', :other51, 4], ['episode', :stereo, 4]
].freeze

def group_of(media)
  ch = media['audioChannels'].to_i
  return :stereo if ch <= 2
  return :dolby51 if %w[ac3 eac3].include?(media['audioCodec'])

  :other51
end

def plan!
  rng = Random.new(SEED)
  picks = []
  STRATA.each do |kind, group, n|
    key, type = kind == 'movie' ? [1, 1] : [2, 4]
    pool = PlexProbe.items(key, type).select do |m|
      md = m.dig('Media', 0) or next false
      part = md.dig('Part', 0) or next false
      group_of(md) == group && part['size'].to_i.between?(1, MAX_BYTES) && m['duration'].to_i > 10 * 60_000
    end
    pool.sample(n, random: rng).each do |m|
      md = m['Media'][0]
      picks << { kind: kind, group: group, plex_id: m['ratingKey'], title: m['grandparentTitle'] ? "#{m['grandparentTitle']} S#{m['parentIndex']}E#{m['index']} #{m['title']}" : "#{m['title']} (#{m['year']})",
                 part_key: md['Part'][0]['key'], bytes: md['Part'][0]['size'], duration_ms: m['duration'],
                 plex_codec: md['audioCodec'], plex_channels: md['audioChannels'], resolution: md['videoResolution'] }
    end
  end
  # interleave so a partial run is still balanced across kinds and groups
  by = picks.group_by { |p| [p[:kind], p[:group]] }.values
  ordered = []
  ordered << by.map(&:shift).compact until by.all?(&:empty?)
  FileUtils.mkdir_p(DATA)
  File.write(PLAN, JSON.pretty_generate(seed: SEED, picks: ordered.flatten))
  puts "planned #{ordered.flatten.size} files; #{picks.group_by { |p| [p[:kind], p[:group]] }.transform_values(&:size)}"
end

def wait_for_idle(deadline, label)
  loop do
    busy = PlexProbe.busy_sessions
    return true if busy.empty?
    return false if Time.now >= deadline

    puts "#{Time.now.strftime('%H:%M:%S')} plex busy (#{busy.first(2).join('; ')}), waiting before #{label}"
    sleep POLL_S
  end
end

# One Plex read at a time across all workers: concurrent reads came back truncated or as 5xx / I/O errors.
def plex_exclusive
  File.open(File.join(Dir.tmpdir, 'neutraliser-0005-fetch.lock'), File::CREAT | File::RDWR) do |lock|
    lock.flock(File::LOCK_EX)
    yield
  end
end

def ffmpeg_headers = ['-headers', "X-Plex-Token: #{PlexProbe::TOKEN}\r\n"]

# ---- subtitles ---------------------------------------------------------------------------------------

Cue = Struct.new(:from, :to, :text)

def parse_srt(text)
  text.gsub("\r", '').split(/\n\n+/).filter_map do |block|
    lines = block.lines.map(&:chomp)
    ts = lines.find { |l| l.include?('-->') } or next
    m = ts.match(/(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)/) or next
    f = ->(h, mi, s, ms) { (h.to_i * 3600) + (mi.to_i * 60) + s.to_i + (ms.to_i / 1000.0) }
    body = lines[(lines.index(ts) + 1)..].join(' ').gsub(/<[^>]+>|\{[^}]*\}/, '').strip
    Cue.new(f.call(*m[1..4]), f.call(*m[5..8]), body)
  end
end

# Cues that are speech: not sound descriptions ([door slams]), not music/lyrics (note symbols), not empty.
def speech_cue?(cue)
  t = cue.text
  return false if t.empty? || t.match?(/[♪♫#]/)
  return false if t.match?(/\A[\[(].*[\])]\z/)

  t.gsub(/\[[^\]]*\]|\([^)]*\)/, '').strip.length >= 2 && (cue.to - cue.from) >= 0.3
end

# ---- loudness series ---------------------------------------------------------------------------------

# Momentary loudness (400 ms window, every 100 ms) of the full mix and of the centre channel alone,
# from one local decode: { t => [full_M, centre_M] } as parallel arrays.
def momentary_series(mka, track_index)
  graph = "[0:a:#{track_index}]asplit[a][b];[a]ebur128@full=framelog=info:peak=none[o1];" \
          "[b]pan=mono|c0=c2,ebur128@centre=framelog=info:peak=none[o2]"
  cmd = ['ffmpeg', '-hide_banner', '-nostats', '-drc_scale', '0', '-i', mka, '-filter_complex', graph,
         '-map', '[o1]', '-map', '[o2]', '-f', 'null', '-']
  _, err, st = Open3.capture3(*cmd)
  raise "momentary series failed: #{err.lines.last(3).join}" unless st.success?

  series = { 'full' => [], 'centre' => [] }
  err.each_line do |l|
    next unless (m = l.match(/ebur128@(full|centre) @ [^\]]+\] t: ([\d.]+)\s+TARGET:\S+ LUFS\s+M:\s*(-?[\d.]+|-?inf)/))

    series[m[1]] << [m[2].to_f, m[3].to_f]
  end
  series
end

# BS.1770 integrated loudness of a set of 400 ms block levels (absolute gate -70, relative gate -10 LU).
def integrated(levels)
  lv = levels.select { |x| x > -70 }
  return nil if lv.empty?

  power = ->(xs) { xs.sum { |x| 10**(x / 10.0) } / xs.size }
  gate = (10 * Math.log10(power.call(lv))) - 10
  kept = lv.select { |x| x > gate }
  return nil if kept.empty?

  10 * Math.log10(power.call(kept)) # M values already carry the -0.691 K-weighting offset
end

# Which blocks (index into the series) lie fully inside a cue, once the cues are shifted by `shift` s.
def cue_mask(times, cues, shift)
  starts = cues.map { |c| c.from + shift }
  ends = cues.map { |c| c.to + shift }
  ci = 0
  times.map do |t|
    ci += 1 while ci < cues.size && ends[ci] < t - 0.4
    j = ci
    inside = false
    while j < cues.size && starts[j] <= t - 0.4 + 1e-6
      (inside = true) && break if ends[j] >= t - 1e-6
      j += 1
    end
    inside
  end
end

# Subtitle clock vs audio clock: the shift (s) that best separates centre-channel loudness inside cues from
# outside them. Also returns that separation in dB: how well the cues explain where the speech is.
def best_shift(times, centre_m, cues)
  best = nil
  (-80..80).step(2).each do |k|
    shift = k * 0.1
    mask = cue_mask(times, cues, shift)
    ins = centre_m.each_index.select { |i| mask[i] && centre_m[i] > -70 }.map { |i| centre_m[i] }
    out = centre_m.each_index.select { |i| !mask[i] && centre_m[i] > -70 }.map { |i| centre_m[i] }
    next if ins.size < 50 || out.size < 50

    sep = (ins.sum / ins.size) - (out.sum / out.size)
    best = { shift: shift.round(1), separation: sep.round(2) } if best.nil? || sep > best[:separation]
  end
  zero_mask = cue_mask(times, cues, 0.0)
  zi = centre_m.each_index.select { |i| zero_mask[i] && centre_m[i] > -70 }.map { |i| centre_m[i] }
  zo = centre_m.each_index.select { |i| !zero_mask[i] && centre_m[i] > -70 }.map { |i| centre_m[i] }
  zero_sep = zi.empty? || zo.empty? ? nil : ((zi.sum / zi.size) - (zo.sum / zo.size)).round(2)
  best && best.merge(separation_at_zero: zero_sep)
end

# ---- one file ---------------------------------------------------------------------------------------

def probe_remote(url)
  out, err, st = Open3.capture3('ffprobe', '-hide_banner', '-v', 'info', '-show_streams', '-show_format', '-of', 'json',
                                *ffmpeg_headers, url)
  raise "probe failed: #{err.lines.last}" unless st.success?

  [out, err]
end

# Download (stream copy) the primary audio and one English text subtitle. Aborts, returning false, if Plex
# turns busy part-way so the library is never read while someone is watching.
def fetch(url, track_index, sub_index, mka, srt, deadline)
  cmd = ['ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-v', 'error', '-y', *ffmpeg_headers, '-i', url,
         '-map', "0:a:#{track_index}", '-c', 'copy', '-map_metadata', '0', mka]
  cmd += ['-map', "0:s:#{sub_index}", '-c:s', 'srt', srt] if sub_index
  pid = Process.spawn(*cmd, err: File::NULL, out: File::NULL)
  aborted = false
  watcher = Thread.new do
    loop do
      sleep 15
      next if PlexProbe.busy_sessions.empty?

      aborted = true
      Process.kill('TERM', pid) rescue nil
      break
    end
  end
  Process.wait(pid)
  watcher.kill
  ok = $?.success? && !aborted
  FileUtils.rm_f([mka, srt]) unless ok
  ok ? true : (aborted ? :busy : false)
end

def measure(item, mka, srt, track, source)
  rec = {}
  # an AC-3/E-AC-3 track's own dialnorm and any NEUTRALISER stamp the track already carries
  local = Neutraliser::Source.new(mka)
  stamp = local.stamp
  rec[:stamped] = !stamp.nil?
  rec[:stamp_mode] = stamp&.mode.to_s if stamp
  rec[:dialnorm] = Neutraliser::DialogueMeter.dialnorm(mka, local.primary_track, stamp)
  ltrack = local.primary_track
  prog = Neutraliser::FFmpegWrapper.measure_loudness(mka, audio_index: ltrack[:index], **Neutraliser::Measurement.side_channels(ltrack))
  rec[:programme] = { i: prog.input_i, tp: prog.input_tp, lra: prog.input_lra, silent: prog.silent? }
  est = Neutraliser::DialogueMeter.estimate(mka, ltrack)
  rec[:estimate] = est.available? ? { level: est.level, method: est.method.to_s } : { reason: est.reason }

  if est.available? && File.exist?(srt)
    cues = parse_srt(File.read(srt, encoding: 'UTF-8', invalid: :replace)).select { |c| speech_cue?(c) }
    rec[:cues] = { count: cues.size, speech_seconds: cues.sum { |c| c.to - c.from }.round(1) }
    if cues.size >= 30
      series = momentary_series(mka, ltrack[:index])
      n = [series['full'].size, series['centre'].size].min
      times = series['full'].first(n).map(&:first)
      full = series['full'].first(n).map(&:last)
      centre = series['centre'].first(n).map(&:last)
      valid = (0...n).select { |i| times[i] >= 0.4 }
      times, full, centre = [times, full, centre].map { |a| valid.map { |i| a[i] } }
      sync = best_shift(times, centre, cues)
      if sync
        mask = cue_mask(times, cues, sync[:shift])
        idx = mask.each_index.select { |i| mask[i] }
        rec[:sync] = sync
        rec[:cue_ref] = { blocks: idx.size, coverage: (idx.size.to_f / times.size).round(3),
                          full_mix: integrated(idx.map { |i| full[i] })&.round(2),
                          centre: integrated(idx.map { |i| centre[i] })&.round(2),
                          centre_whole_file: integrated(centre)&.round(2),
                          full_mix_whole_file: integrated(full)&.round(2) }
        zero = cue_mask(times, cues, 0.0)
        zi = zero.each_index.select { |i| zero[i] }
        rec[:cue_ref_unshifted] = { full_mix: integrated(zi.map { |i| full[i] })&.round(2), centre: integrated(zi.map { |i| centre[i] })&.round(2) }
      end
    end
  end
  rec
end

def process(item, deadline)
  url = "#{PlexProbe::BASE}#{item['part_key']}"
  json, err = plex_exclusive { probe_remote(url) }
  source = Neutraliser::Source.from_ffprobe(url, json, err)
  track = source.primary_track
  streams = JSON.parse(json)['streams']
  subs = streams.select { |s| s['codec_type'] == 'subtitle' }
  text_subs = subs.each_with_index.select { |s, _| %w[subrip ass ssa mov_text webvtt text].include?(s['codec_name']) }
  pick = text_subs.find { |s, _| s.dig('tags', 'language') == 'eng' && s['disposition']['hearing_impaired'].to_i.zero? && s['disposition']['forced'].to_i.zero? } ||
         text_subs.find { |s, _| s.dig('tags', 'language') == 'eng' && s['disposition']['forced'].to_i.zero? }
  sub_index = pick&.last
  rec = { title: item['title'], kind: item['kind'], group: item['group'], plex_id: item['plex_id'], bytes: item['bytes'],
          duration_s: (item['duration_ms'] / 1000.0).round, resolution: item['resolution'],
          track: { index: track[:index], codec: track[:codec], channels: track[:channels], layout: track[:channel_layout],
                   profile: track[:profile], language: track[:language], bit_rate: track[:bit_rate] },
          subtitle: pick ? { codec: pick.first['codec_name'], index: sub_index, hi: pick.first['disposition']['hearing_impaired'] } : nil,
          subtitle_tracks_all: subs.size }
  Dir.mktmpdir('neutraliser-0005') do |dir|
    mka = File.join(dir, 'audio.mka')
    srt = File.join(dir, 'sub.srt')
    t0 = Time.now
    # one download at a time: concurrent reads from Plex came back truncated yet "successful"
    got = plex_exclusive { fetch(url, track[:index], sub_index, mka, srt, deadline) }
    return :busy if got == :busy
    raise 'download failed' unless got

    got_s = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mka).first.to_f
    expected_s = item['duration_ms'] / 1000.0
    raise "truncated read: #{got_s.round}s of #{expected_s.round}s" if got_s < expected_s * 0.97
    rec[:audio_seconds] = got_s.round

    rec[:fetch_s] = (Time.now - t0).round
    t1 = Time.now
    rec.merge!(measure(item, mka, srt, track, source))
    rec[:measure_s] = (Time.now - t1).round
  end
  rec
end

def run!(until_hhmm, shard)
  plan = JSON.parse(File.read(RUN_PLAN))['picks']
  k, n = shard.to_s.split('/').map(&:to_i)
  plan = plan.each_with_index.select { |_, i| i % n == k }.map(&:first) if n.to_i.positive?
  deadline = Time.parse(until_hhmm || '07:00')
  deadline += 86_400 if deadline < Time.now - 3600
  done = File.exist?(RESULTS) ? File.readlines(RESULTS).map { |l| JSON.parse(l)['plex_id'] } : []
  plan.each do |item|
    next if done.include?(item['plex_id'])

    attempts = 0
    loop do
      break puts('deadline reached') || exit(0) unless wait_for_idle(deadline, item['title'])

      puts "#{Time.now.strftime('%H:%M:%S')} measuring #{item['title']} (#{item['plex_codec']} #{item['plex_channels']}ch, #{(item['bytes'] / 1e9).round(1)} GB)"
      begin
        rec = process(item, deadline)
      rescue StandardError => e
        attempts += 1
        puts "  error: #{e.class}: #{e.message.lines.first(2).join.strip}"
        sleep 45
        if attempts >= 2
          File.open(RESULTS, 'a') { |f| f.puts JSON.generate(item.merge('error' => e.message.lines.first.to_s.strip)) }
          break
        end
        next
      end
      if rec == :busy
        puts '  plex went busy mid-read; stopped and will retry'
        sleep POLL_S
        next
      end
      File.open(RESULTS, 'a') { |f| f.puts JSON.generate(rec) }
      puts "  dialnorm=#{rec[:dialnorm].inspect} programme=#{rec[:programme][:i]} estimate=#{rec[:estimate].inspect} cue_ref=#{rec.dig(:cue_ref, :full_mix).inspect}"
      break
    end
  end
  puts 'plan finished'
end

if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when 'plan' then plan!
  when 'run' then run!(ARGV[1], ARGV[2]) # ARGV[2]: K/N runs every Nth planned file starting at K
  else abort 'usage: plan | run [HH:MM]'
  end
end
