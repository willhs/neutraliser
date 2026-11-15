# Research 0005 screening: cheaply find (a) Dolby 5.1 files whose dialnorm is not -31 (ground truth for the
# estimate) and (b) films with an English text subtitle and a musical / heavy-score genre (cue reference).
# Reads only the container header and the first 8 audio frames of each candidate over Plex (a few MB).
# Writes data/screen.jsonl, then `pick` writes data/plan2.json (extra files for dialogue_real_files.rb run).
require_relative 'dialogue_real_files'

SCREEN = File.join(DATA, 'screen.jsonl')
PLAN2 = File.join(DATA, 'plan2.json')
SCORE_GENRES = %w[Action Adventure Science\ Fiction War Fantasy Thriller].freeze
SONG_GENRES = %w[Musical Music].freeze

def candidates
  rng = Random.new(SEED + 1 + ENV.fetch('SCREEN_SEED', '0').to_i)
  planned = JSON.parse(File.read(PLAN))['picks'].map { |p| p['plex_id'] }
  pools = { 'movie' => PlexProbe.items(1, 1), 'episode' => PlexProbe.items(2, 4) }
  out = []
  pools.each do |kind, items|
    ok = items.select do |m|
      md = m.dig('Media', 0) or next false
      %w[ac3 eac3].include?(md['audioCodec']) && md['audioChannels'].to_i >= 6 && !planned.include?(m['ratingKey']) &&
        md.dig('Part', 0, 'size').to_i.between?(1, MAX_BYTES) && m['duration'].to_i > 10 * 60_000
    end
    musical = ok.select { |m| (m['Genre'] || []).any? { |g| SONG_GENRES.include?(g['tag']) } }
    rest = (ok - musical).sample(kind == 'movie' ? ENV.fetch('SCREEN_MOVIES', '45').to_i : ENV.fetch('SCREEN_EPS', '35').to_i, random: rng)
    (musical + rest).each { |m| out << [kind, m] }
  end
  out
end

def screen!
  seen = File.exist?(SCREEN) ? File.readlines(SCREEN).map { |l| JSON.parse(l)['plex_id'] } : []
  deadline = Time.parse('07:00')
  deadline += 86_400 if deadline < Time.now - 3600
  candidates.each do |kind, m|
    next if seen.include?(m['ratingKey'])
    break puts('deadline') unless wait_for_idle(deadline, m['title'])

    md = m['Media'][0]
    url = "#{PlexProbe::BASE}#{md['Part'][0]['key']}"
    rec = { plex_id: m['ratingKey'], kind: kind, title: m['grandparentTitle'] ? "#{m['grandparentTitle']} S#{m['parentIndex']}E#{m['index']} #{m['title']}" : "#{m['title']} (#{m['year']})",
            genres: (m['Genre'] || []).map { |g| g['tag'] }, part_key: md['Part'][0]['key'], bytes: md['Part'][0]['size'], duration_ms: m['duration'],
            plex_codec: md['audioCodec'], plex_channels: md['audioChannels'], resolution: md['videoResolution'], group: 'dolby51' }
    begin
      json, err = probe_remote(url)
      track = Neutraliser::Source.from_ffprobe(url, json, err).primary_track
      streams = JSON.parse(json)['streams']
      eng_text = streams.select { |s| s['codec_type'] == 'subtitle' && %w[subrip ass ssa mov_text webvtt].include?(s['codec_name']) && s.dig('tags', 'language') == 'eng' }
      Dir.mktmpdir('neutraliser-0005s') do |dir|
        raw = File.join(dir, "head.#{track[:codec]}")
        _, e, st = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-v', 'error', '-y', *ffmpeg_headers, '-i', url, '-map', "0:a:#{track[:index]}",
                                  '-c', 'copy', '-frames:a', '8', '-f', track[:codec], raw)
        rec[:dialnorm] = st.success? ? Neutraliser::DolbyStream.dialnorm(File.binread(raw)) : nil
        rec[:dialnorm_error] = e.lines.first&.strip unless st.success?
      end
      rec[:track] = { index: track[:index], codec: track[:codec], channels: track[:channels] }
      rec[:eng_text_subs] = eng_text.size
    rescue StandardError => e
      rec[:error] = e.message.lines.first.to_s.strip
    end
    File.open(SCREEN, 'a') { |f| f.puts JSON.generate(rec) }
    puts "#{rec[:title]}: dialnorm=#{rec[:dialnorm].inspect} subs=#{rec[:eng_text_subs].inspect} #{rec[:error]}"
  end
end

# Extra measuring plan: files with a real dialnorm (up to 14), then films with songs / heavy score that have
# English text subtitles (up to 5 + 5). Whatever the screen found.
def pick!
  rows = File.readlines(SCREEN).map { |l| JSON.parse(l, symbolize_names: true) }.reject { |r| r[:error] }
  real = rows.select { |r| r[:dialnorm] && r[:dialnorm] != -31 }
  with_subs = rows.select { |r| r[:eng_text_subs].to_i.positive? }
  songs = with_subs.select { |r| r[:kind] == 'movie' && (r[:genres] & SONG_GENRES).any? }.first(5)
  score = (with_subs - songs).select { |r| r[:kind] == 'movie' && (r[:genres] & SCORE_GENRES).any? }.first(5)
  picks = (real.first(14) + songs + score).uniq { |r| r[:plex_id] }
  picks.each { |r| r[:why] = [(:dialnorm if real.include?(r)), (:songs if songs.include?(r)), (:score if score.include?(r))].compact }
  File.write(PLAN2, JSON.pretty_generate(seed: SEED + 1, picks: picks.map { |r| r.transform_keys(&:to_s) }))
  puts "screened #{rows.size}; real dialnorm #{real.size}; with eng text subs #{with_subs.size}; picked #{picks.size} (songs #{songs.size}, score #{score.size})"
  puts "dialnorm values: #{rows.map { |r| r[:dialnorm] }.tally.sort_by { |k, _| k.to_i }.to_h}"
end

# The rest of the screened files with a real dialnorm, once plan2's first 14 are measured (plan3.json).
def pick3!
  rows = File.readlines(SCREEN).map { |l| JSON.parse(l, symbolize_names: true) }.reject { |r| r[:error] }
  planned = [PLAN, PLAN2].flat_map { |f| JSON.parse(File.read(f))['picks'].map { |r| r['plex_id'].to_s } }
  extra = rows.select { |r| r[:dialnorm] && r[:dialnorm] != -31 && !planned.include?(r[:plex_id].to_s) }.uniq { |r| r[:plex_id] }
  extra.each { |r| r[:why] = [:dialnorm] }
  File.write(File.join(DATA, 'plan3.json'), JSON.pretty_generate(seed: SEED + 1, picks: extra.map { |r| r.transform_keys(&:to_s) }))
  puts "plan3: #{extra.size} more files with a real dialnorm: #{extra.map { |r| r[:title] }.inspect}"
end

case ARGV[0]
when 'pick3' then pick3!
when 'screen' then screen!
when 'pick' then pick!
else abort 'usage: screen | pick'
end
