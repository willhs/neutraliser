# Research 0006: run the current measure / plan path on real 7.1 and Atmos tracks, read-only, Plex-idle-gated.
#
#   ruby real_71.rb plan                    # pick the sample from data/scan.jsonl -> data/plan.json
#   ruby real_71.rb run [UNTIL_HHMM] [K/N]  # measure each planned file -> data/results.jsonl
#
# Per file: ONE Plex read (the primary audio track stream-copied into a scratch .mkv named like the library
# file, so the name hint of ObjectAudio still works). Everything else runs on that scratch copy:
#   - the current meter (FFmpegWrapper.measure_loudness with Measurement.side_channels) and loudnorm alone
#   - a plain `ffmpeg ebur128` read, and lab/bs1770.py (numpy BS.1770-4 + EBU 3342) as independent readings
#   - the real GainPlan / Compression.needed? for the decision, and `bin/neutraliser process --dry-run`
#     (default, --ladder, --ladder + both allow flags) on the scratch copy
#   - the real PlexAnalyzer item path (sampled windows over Plex; --full for a few small ones)
# Nothing is written to the library, Plex or the NAS. Scratch is deleted per file.
require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'time'
require_relative '../../0005-dialogue-estimate-real-files/lab/dialogue_real_files'

OUT_DIR = File.expand_path('../data', __dir__)
SCAN_FILE = File.join(OUT_DIR, 'scan.jsonl')
PLAN_FILE = File.join(OUT_DIR, 'plan.json')
RESULTS_FILE = File.join(OUT_DIR, 'results.jsonl')
BIN = File.expand_path('../../../../bin/neutraliser', __dir__)
BS1770 = File.join(__dir__, 'bs1770.py')

# plex_id => why it is in. 8-channel primary tracks over every codec the library has, then Atmos E-AC-3 (JOC)
# on a film and an episode, then a title whose NAME claims Atmos but whose stream (E-AC-3 5.1) does not.
PICKS = {
  '10123' => 'TrueHD Atmos 7.1, animated film', '16746' => 'TrueHD Atmos 7.1, drama', '7018' => 'TrueHD Atmos 7.1, action',
  '7036' => 'E-AC-3 7.1, film', '7315' => 'E-AC-3 7.1, film', '8330' => 'E-AC-3 7.1 that is not the default track',
  '9346' => 'HE-AAC 7.1', '10557' => 'AAC-LC 7.1', '12147' => 'FLAC 7.1',
  '14135' => 'E-AC-3 JOC Atmos 5.1, episode', '8947' => 'E-AC-3 JOC Atmos 5.1, film', '14108' => 'name says TrueHD 7.1 Atmos, stream is E-AC-3 5.1'
}.freeze
FULL_READ_IDS = %w[14108 9346].freeze # analyze-plex --full over Plex on the two smallest

def plan6!
  scan = File.readlines(SCAN_FILE).map { |l| JSON.parse(l) }
  picks = PICKS.map do |id, why|
    rows = scan.select { |r| r['plex_id'] == id }
    row = rows.find { |r| r['channels'] >= 7 } || rows.first or raise "#{id} not in scan"
    row.slice('plex_id', 'kind', 'title', 'duration_ms', 'bytes', 'part_key', 'codec', 'channels', 'profile').merge('why' => why)
  end
  File.write(PLAN_FILE, JSON.pretty_generate(picks: picks))
  puts "planned #{picks.size}: #{picks.map { |p| p['title'] }.inspect}"
end

# ---- readings --------------------------------------------------------------------------------------

def reading(measurement)
  { i: measurement.input_i, tp: measurement.input_tp, lra: measurement.input_lra, silent: measurement.silent? }
end

# A plain ffmpeg ebur128 read of the track: no neutraliser code but the DRC-off flag the product also uses.
def ebur128_plain(path, index)
  _, err, st = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-drc_scale', '0', '-i', path, '-map', "0:a:#{index}",
                              '-af', 'ebur128=peak=true', '-f', 'null', '-')
  raise "ebur128 failed: #{err.lines.last}" unless st.success?

  s = err[err.rindex('Summary:')..]
  { i: s[/I:\s+(-?[\d.]+) LUFS/, 1].to_f, lra: s[/LRA:\s+(-?[\d.]+) LU/, 1].to_f, tp: s[/Peak:\s+(-?[\d.]+) dBFS/, 1].to_f }
end

def numpy_meter(path, index)
  out, err, st = Open3.capture3('python3', BS1770, path, index.to_s)
  raise "bs1770.py failed: #{err.lines.last(2).join}" unless st.success?

  JSON.parse(out, symbolize_names: true)
end

def timed
  t = Time.now
  [yield, (Time.now - t).round(1)]
end

# Rung the ladder would take, from the real GainPlan and Compression.needed? on the measurement: nil-free text.
def decision(measurement, profile, ladder:)
  limit = ladder ? Neutraliser::Ladder::LIMIT_DB : 0.0
  plan = Neutraliser::GainPlan.for(measurement, profile, limit_db: limit)
  worthwhile = plan.worthwhile?(1.0)
  within = (measurement.input_i - profile[:lufs]).abs <= 1.0
  compress = ladder && Neutraliser::Compression.needed?(measurement, lra_target: Neutraliser::Ladder::LRA_LIMIT, tolerance: 1.0)
  outcome = if measurement.silent? then 'skip silent'
            elsif compress then 'compress (rung 3), if a rung narrows it'
            elsif within then 'skip within_tolerance'
            elsif !worthwhile then 'skip peak_limited'
            elsif plan.limited then 'normalise, limiter (rung 2)'
            else 'normalise, gain (rung 1)'
            end
  { outcome: outcome, desired_db: plan.desired.round(2), applied_db: plan.applied.round(2), limited: plan.limited }
end

def cli_dry_run(dir, file, *flags)
  env = { 'PATH' => "#{Dir.home}/.rbenv/shims:#{ENV['PATH']}", 'LANG' => 'en_US.UTF-8' }
  out, st = Open3.capture2e(env, BIN, 'process', file, '--dry-run', *flags, chdir: dir)
  lines = out.lines.map { |l| l.sub(/\A\[[^\]]*\]\s*/, '').rstrip }.reject(&:empty?)
  { exit: st.exitstatus, lines: lines.map { |l| l.gsub(dir, '<scratch>') } }
end

def analyze_plex_item(item_id, full:)
  meta = PlexProbe.get("/library/metadata/#{item_id}")['Metadata'].first
  analyzer = Neutraliser::PlexAnalyzer.new(server_url: PlexProbe::BASE, token: PlexProbe::TOKEN, full: full)
  analyzer.instance_variable_set(:@server_url, PlexProbe::BASE)
  analyzer.instance_variable_set(:@auth_token, PlexProbe::TOKEN)
  res, secs = timed { analyzer.send(:analyze_media_item, meta, 'movie') }
  return { result: nil, seconds: secs } unless res

  { level: res[:current_level]&.round(2), range: res[:level_range].map { |x| x.round(2) }, measured: res[:measured].to_s,
    verdict: res[:verdict].to_s, level_difference: res[:level_difference].round(2), seconds: secs }
end

def track_summary(t)
  t.slice(:index, :codec, :channels, :channel_layout, :profile, :language, :title, :default, :bit_rate)
end

# ---- one file --------------------------------------------------------------------------------------

def fetch6(url, track_index, out, expected_s)
  cmd = ['ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-v', 'error', '-y', *ffmpeg_headers, '-i', url,
         '-map', "0:a:#{track_index}", '-c', 'copy', '-map_metadata', '0', out]
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
  return (aborted ? :busy : false) unless $?.success? && !aborted

  got = Open3.capture2('ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', out).first.to_f
  raise "truncated read: #{got.round}s of #{expected_s.round}s" if got < expected_s * 0.97

  got
end

def process6(item)
  id = item['plex_id']
  meta = PlexProbe.get("/library/metadata/#{id}")['Metadata'].first
  basename = File.basename(meta.dig('Media', 0, 'Part', 0, 'file'))
  url = "#{PlexProbe::BASE}#{item['part_key']}"
  json, err = plex_exclusive { probe_remote(url) }
  remote = Neutraliser::Source.from_ffprobe(url, json, err)
  primary = remote.primary_track
  rec = { plex_id: id, title: item['title'], kind: item['kind'], why: item['why'], bytes: item['bytes'],
          duration_s: (item['duration_ms'] / 1000.0).round, resolution: meta.dig('Media', 0, 'videoResolution'),
          plex: { audio_codec: meta.dig('Media', 0, 'audioCodec'), audio_channels: meta.dig('Media', 0, 'audioChannels'),
                  media_count: meta['Media']&.size },
          audio_tracks: remote.audio_tracks.map { |t| track_summary(t) }, primary_index: primary[:index],
          first_track_is_primary: primary[:index].zero?, name_hint: Neutraliser::ObjectAudio.hinted?(basename, primary[:title]) }
  Dir.mktmpdir('neutraliser-0006') do |dir|
    mkv = File.join(dir, "#{File.basename(basename, '.*')}.mkv")
    t0 = Time.now
    got = plex_exclusive { fetch6(url, primary[:index], mkv, rec[:duration_s]) }
    return :busy if got == :busy
    raise 'download failed' unless got

    rec[:fetch_s] = (Time.now - t0).round
    local = Neutraliser::Source.new(mkv)
    track = local.primary_track
    rec[:local_track] = track_summary(track)
    verdict = Neutraliser::ObjectAudio.detect(local, name: File.basename(basename))
    rec[:object_audio] = { status: verdict.status.to_s, profile: verdict.profile,
                           remote_profile_after_probe: primary[:profile] }
    rec[:channels] = track[:channels]
    ch = Neutraliser::Measurement.side_channels(track)

    # The product's own path first: `process --dry-run` measures through AudioAnalyser and caches the figure in
    # a sidecar in the scratch folder. That cached figure is the "current" reading when there is one (it is the
    # same call as measure_loudness with side channels); files the guards skip before measuring get a direct read.
    rec[:cli_default] = cli_dry_run(dir, mkv)
    cache = File.join(dir, "#{File.basename(mkv, '.*')}.loudnorm_livingroom.json")
    cached = File.exist?(cache) && Neutraliser::Measurement.from_cache_h(JSON.parse(File.read(cache)))
    if cached
      cur = cached
      rec[:current_source] = 'process --dry-run cache'
    else
      cur, rec[:current_s] = timed { Neutraliser::FFmpegWrapper.measure_loudness(mkv, audio_index: track[:index], **ch) }
      rec[:current_source] = 'FFmpegWrapper.measure_loudness'
    end
    base, rec[:loudnorm_only_s] = timed { Neutraliser::FFmpegWrapper.measure_loudness(mkv, audio_index: track[:index]) }
    rec[:current] = reading(cur)
    rec[:loudnorm_only] = reading(base)
    rec[:ebur128_plain], rec[:ebur128_s] = timed { ebur128_plain(mkv, track[:index]) }
    rec[:numpy], rec[:numpy_s] = timed { numpy_meter(mkv, track[:index]) }

    profile = Neutraliser::Profiles.get_profile('livingroom')
    rec[:decision_recipe2] = decision(cur, profile, ladder: false)
    rec[:decision_ladder] = decision(cur, profile, ladder: true)
    rec[:decision_if_old_meter] = decision(base, profile, ladder: true) # what the six-channel meter would have decided

    rec[:cli_ladder] =cli_dry_run(dir, mkv, '--ladder')
    rec[:cli_ladder_allow] = cli_dry_run(dir, mkv, '--ladder', '--allow-codec-change', '--allow-object-audio-loss')
  end
  rec
end

def plex_part(id, full)
  analyze_plex_item(id, full: full)
rescue StandardError => e
  { error: e.message.lines.first.to_s.strip }
end

def run6!(until_hhmm, shard)
  plan = JSON.parse(File.read(PLAN_FILE))['picks']
  k, n = shard.to_s.split('/').map(&:to_i)
  plan = plan.each_with_index.select { |_, i| i % n == k }.map(&:first) if n.to_i.positive?
  deadline = Time.parse(until_hhmm || '07:00')
  deadline += 86_400 if deadline < Time.now - 3600
  done = File.exist?(RESULTS_FILE) ? File.readlines(RESULTS_FILE).map { |l| JSON.parse(l)['plex_id'] } : []
  plan.each do |item|
    next if done.include?(item['plex_id'])

    attempts = 0
    loop do
      break puts('deadline reached') || exit(0) unless wait_for_idle(deadline, item['title'])

      puts "#{Time.now.strftime('%H:%M:%S')} #{item['title']} (#{item['codec']} #{item['channels']}ch, #{(item['bytes'] / 1e9).round(1)} GB)"
      begin
        rec = process6(item)
      rescue StandardError => e
        attempts += 1
        puts "  error: #{e.class}: #{e.message.lines.first(2).join.strip}"
        sleep 45
        if attempts >= 2
          File.open(RESULTS_FILE, 'a') { |f| f.puts JSON.generate(item.merge('error' => e.message.lines.first.to_s.strip)) }
          break
        end
        next
      end
      if rec == :busy
        puts '  plex went busy mid-read; stopped and will retry'
        sleep POLL_S
        next
      end
      if wait_for_idle(deadline, "analyze-plex #{item['title']}")
        # one Plex read at a time, as for the fetch: overlapping streams get closed early by Plex
        rec[:analyze_plex_sampled] = plex_exclusive { plex_part(item['plex_id'], false) }
        rec[:analyze_plex_full] = plex_exclusive { plex_part(item['plex_id'], true) } if FULL_READ_IDS.include?(item['plex_id'])
      end
      File.open(RESULTS_FILE, 'a') { |f| f.puts JSON.generate(rec) }
      puts "  current=#{rec[:current].inspect} loudnorm_only=#{rec[:loudnorm_only].inspect} ebur=#{rec[:ebur128_plain].inspect} numpy=#{rec[:numpy].slice(:i, :lra).inspect}"
      break
    end
  end
  puts 'plan finished'
end

ANALYZE_FILE = File.join(OUT_DIR, 'analyze_plex.jsonl')

# analyze-plex's own item path for every planned file, one Plex read at a time and nothing else running, so no
# window is cut short by an overlapping read. (The per-file runs above did theirs while other shards read.)
def analyze6!
  done = File.exist?(ANALYZE_FILE) ? File.readlines(ANALYZE_FILE).map { |l| JSON.parse(l)['plex_id'] } : []
  JSON.parse(File.read(PLAN_FILE))['picks'].each do |item|
    next if done.include?(item['plex_id'])

    sleep POLL_S until PlexProbe.busy_sessions.empty?
    rec = { plex_id: item['plex_id'], title: item['title'], channels_plex: PlexProbe.get("/library/metadata/#{item['plex_id']}")['Metadata'].first.dig('Media', 0, 'audioChannels'),
            sampled: plex_exclusive { plex_part(item['plex_id'], false) } }
    rec[:full] = plex_exclusive { plex_part(item['plex_id'], true) } if FULL_READ_IDS.include?(item['plex_id'])
    File.open(ANALYZE_FILE, 'a') { |f| f.puts JSON.generate(rec) }
    puts "#{item['title']}: #{rec[:sampled].inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when 'analyze' then analyze6!
  when 'plan' then plan6!
  when 'run' then run6!(ARGV[1], ARGV[2])
  else abort 'usage: plan | run [HH:MM] [K/N]'
  end
end
