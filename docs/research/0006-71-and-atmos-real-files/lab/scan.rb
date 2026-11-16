# Research 0006 step 1: count 7.1 and Atmos / DTS:X audio tracks in the Plex library, read-only.
# Reads each title's stream list from Plex's metadata API (JSON only, no media bytes). Writes
# data/scan.jsonl (one record per title with any audio stream of 7+ channels or an object-audio name) and
# data/scan_summary.json. Never prints the token.
require 'json'
require_relative '../../0005-dialogue-estimate-real-files/lab/plex_probe'

DATA = File.expand_path('../data', __dir__)
OUT = File.join(DATA, 'scan.jsonl')
OBJECT_RE = /atmos|dts:x|dts-x|\bjoc\b/i

def title_of(m)
  m['grandparentTitle'] ? "#{m['grandparentTitle']} S#{m['parentIndex']}E#{m['index']} #{m['title']}" : "#{m['title']} (#{m['year']})"
end

def scan!
  abort "plex busy: #{PlexProbe.busy_sessions.inspect}" unless PlexProbe.busy_sessions.empty?
  pools = { 'movie' => PlexProbe.items(1, 1), 'episode' => PlexProbe.items(2, 4) }
  seen = File.exist?(OUT) ? File.readlines(OUT).map { |l| JSON.parse(l)['plex_id'] } : []
  totals = Hash.new(0)
  hits = []
  File.open(OUT, 'a') do |f|
    pools.each do |kind, items|
      items.each_with_index do |m, i|
        totals["#{kind}_titles"] += 1
        sleep 5 and abort('plex busy') if (i % 200).zero? && i.positive? && !PlexProbe.busy_sessions.empty?
        meta = PlexProbe.get("/library/metadata/#{m['ratingKey']}")['Metadata']&.first or next
        (meta['Media'] || []).each_with_index do |md, mi|
          streams = (md.dig('Part', 0, 'Stream') || []).select { |s| s['streamType'] == 2 }
          streams.each do |s|
            ch = s['channels'].to_i
            names = [s['displayTitle'], s['extendedDisplayTitle'], s['title'], s['audioChannelLayout'], s['profile']].compact.join(' | ')
            obj = names.match?(OBJECT_RE)
            totals["#{kind}_audio_tracks"] += 1
            next unless ch >= 7 || obj

            rec = { plex_id: m['ratingKey'], kind: kind, title: title_of(m), genres: (meta['Genre'] || []).map { |g| g['tag'] },
                    media_index: mi, duration_ms: meta['duration'], bytes: md.dig('Part', 0, 'size'), part_key: md.dig('Part', 0, 'key'),
                    stream_index: s['index'], selected: s['selected'] ? true : false, codec: s['codec'], profile: s['profile'], channels: ch,
                    layout: s['audioChannelLayout'], bit_depth: s['bitDepth'], bitrate: s['bitrate'], language: s['languageTag'],
                    display: s['extendedDisplayTitle'], object_audio_name: obj, resolution: md['videoResolution'] }
            f.puts JSON.generate(rec)
            hits << rec
            totals["#{kind}_71_tracks"] += 1 if ch >= 7
            totals["#{kind}_object_named_tracks"] += 1 if obj
          end
        end
      end
    end
  end
  File.write(File.join(DATA, 'scan_summary.json'), JSON.pretty_generate(totals))
  puts JSON.pretty_generate(totals)
end

scan! if $PROGRAM_NAME == __FILE__
