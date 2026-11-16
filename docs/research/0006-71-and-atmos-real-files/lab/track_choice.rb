# Research 0006: how often is the audio track `analyze-plex` reads (ffmpeg's 0:a:0) not the track a sweep
# would process (Source#primary_track: default disposition, else first English, else a:0), and how often does
# the channel count analyze-plex hands the meter (Plex's Media.audioChannels) differ from that first track's?
# Plex JSON metadata only, no media bytes. Writes data/track_choice.json.
require 'json'
require_relative '../../0005-dialogue-estimate-real-files/lab/plex_probe'

OUT = File.expand_path('../data/track_choice.json', __dir__)

def sweep_pick(streams)
  streams.find { |s| s['default'] } || streams.find { |s| s['languageCode'] == 'eng' } || streams.first
end

tally = Hash.new(0)
examples = []
{ 'movie' => PlexProbe.items(1, 1), 'episode' => PlexProbe.items(2, 4) }.each do |kind, items|
  items.each do |m|
    meta = PlexProbe.get("/library/metadata/#{m['ratingKey']}")['Metadata']&.first or next
    md = meta['Media']&.first or next
    streams = (md.dig('Part', 0, 'Stream') || []).select { |s| s['streamType'] == 2 }.sort_by { |s| s['index'] }
    next if streams.empty?

    tally["#{kind}_titles"] += 1
    tally["#{kind}_multi_audio"] += 1 if streams.size > 1
    first = streams.first
    pick = sweep_pick(streams)
    tally["#{kind}_sweep_pick_not_first"] += 1 if pick != first
    plex_ch = md['audioChannels'].to_i
    tally["#{kind}_plex_channels_differ_from_first"] += 1 if plex_ch != first['channels'].to_i
    tally["#{kind}_plex_channels_differ_from_sweep_pick"] += 1 if plex_ch != pick['channels'].to_i
    over6_first = first['channels'].to_i > 6
    over6_pick = pick['channels'].to_i > 6
    tally["#{kind}_side_channel_decision_differs"] += 1 if (plex_ch > 6) != over6_first
    next unless pick != first && (pick['channels'].to_i != first['channels'].to_i || pick['codec'] != first['codec'])

    examples << { kind: kind, title: meta['grandparentTitle'] ? "#{meta['grandparentTitle']} S#{meta['parentIndex']}E#{meta['index']}" : "#{meta['title']} (#{meta['year']})",
                  plex_audio_channels: plex_ch, first: first.slice('codec', 'channels', 'languageCode', 'default'),
                  sweep_pick: pick.slice('codec', 'channels', 'languageCode', 'default') }
  end
end
File.write(OUT, JSON.pretty_generate(tally: tally, examples: examples.first(40), example_count: examples.size))
puts JSON.pretty_generate(tally)
puts "examples where first and sweep pick differ in codec or channels: #{examples.size}"
