# Research 0006 follow-up: what a real 7.1 lossy track does in the encode path, on a 4-minute slice.
#
#   ruby slices.rb run   -> data/slices.jsonl
#
# For each planned 7.1 E-AC-3 / AAC film: stream-copy a 240 s slice of the primary audio from the middle of the
# film (one small Plex read, inside the film, under the shared one-read-at-a-time lock) into a scratch mkv, then
#   - read its peak and loudness with DRC off (the product's setting) and on (ffmpeg's default), and
#   - run the real `process --replace` (recipe 2) and `process --replace --ladder` on that scratch copy and
#     report what came out (codec, channels, bitrate, status lines).
# Only scratch is written. The library file is read for the slice and nothing else.
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'real_71'

SLICE_FILE = File.join(OUT_DIR, 'slices.jsonl')
SLICE_IDS = %w[7036 7315 9346 10557].freeze # Martian, Star Trek Into Darkness (E-AC-3 7.1); Star Wars III, Fantastic Beasts (AAC 7.1)
SLICE_S = 240

def stream_facts(path)
  out, = Open3.capture2('ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries',
                        'stream=codec_name,channels,channel_layout,bit_rate,profile', '-of', 'json', path)
  JSON.parse(out)['streams'].first
end

def ebur(path, drc)
  _, err, st = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-drc_scale', drc.to_s, '-i', path, '-map', '0:a:0',
                              '-af', 'ebur128=peak=true', '-f', 'null', '-')
  return { error: err.lines.last.to_s.strip } unless st.success?

  s = err[err.rindex('Summary:')..]
  { i: s[/I:\s+(-?[\d.]+) LUFS/, 1].to_f, lra: s[/LRA:\s+(-?[\d.]+) LU/, 1].to_f, tp: s[/Peak:\s+(-?[\d.]+) dBFS/, 1].to_f }
end

def one_slice(item)
  id = item['plex_id']
  meta = PlexProbe.get("/library/metadata/#{id}")['Metadata'].first
  url = "#{PlexProbe::BASE}#{item['part_key']}"
  json, err = plex_exclusive { probe_remote(url) }
  index = Neutraliser::Source.from_ffprobe(url, json, err).primary_track[:index]
  start = (meta['duration'] / 1000.0 / 2).round
  rec = { plex_id: id, title: item['title'], slice_start_s: start, slice_s: SLICE_S }
  Dir.mktmpdir('neutraliser-0006s') do |dir|
    mkv = File.join(dir, 'slice.mkv')
    ok = plex_exclusive do
      system('ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-v', 'error', '-y', *ffmpeg_headers, '-ss', start.to_s, '-t', SLICE_S.to_s,
             '-i', url, '-map', "0:a:#{index}", '-c', 'copy', mkv, err: File::NULL)
    end
    raise 'slice read failed' unless ok

    rec[:source] = stream_facts(mkv)
    rec[:drc_off] = ebur(mkv, 0)
    rec[:drc_on] = ebur(mkv, 1)
    %w[recipe2 ladder].each do |mode|
      work = File.join(dir, mode)
      Dir.mkdir(work)
      copy = File.join(work, 'slice.mkv')
      FileUtils.cp(mkv, copy)
      env = { 'PATH' => "#{Dir.home}/.rbenv/shims:#{ENV['PATH']}", 'LANG' => 'en_US.UTF-8' }
      args = ['process', copy, '--replace', *(mode == 'ladder' ? ['--ladder'] : [])]
      out, st = Open3.capture2e(env, BIN, *args, chdir: work)
      rec[mode] = { exit: st.exitstatus, lines: out.lines.map { |l| l.sub(/\A\[[^\]]*\]\s*/, '').rstrip.gsub(work, '<scratch>') }.reject(&:empty?),
                    after: (File.exist?(copy) ? stream_facts(copy) : nil) }
    end
  end
  rec
end

if $PROGRAM_NAME == __FILE__
  abort 'usage: run' unless ARGV[0] == 'run'
  JSON.parse(File.read(PLAN_FILE))['picks'].select { |p| SLICE_IDS.include?(p['plex_id']) }.each do |item|
    sleep POLL_S until PlexProbe.busy_sessions.empty?
    rec = begin
      one_slice(item)
    rescue StandardError => e
      { plex_id: item['plex_id'], title: item['title'], error: e.message.lines.first.to_s.strip }
    end
    File.open(SLICE_FILE, 'a') { |f| f.puts JSON.generate(rec) }
    puts "#{item['title']}: #{rec.slice(:drc_off, :drc_on, :error).inspect}"
  end
end
