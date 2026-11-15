# Read-only Plex probe: libraries, live sessions, library shape. Never prints the token.
require 'net/http'; require 'json'; require 'uri'
module PlexProbe
  ENV_TEXT = File.read(File.join(__dir__, '..', '..', '..', '..', '.env'))
  BASE = ENV_TEXT[/^PLEX_SERVER_URL=(.*)$/, 1].strip
  TOKEN = ENV_TEXT[/^PLEX_TOKEN=(.*)$/, 1].strip
  module_function

  def get(path)
    u = URI("#{BASE}#{path}")
    req = Net::HTTP::Get.new(u); req['X-Plex-Token'] = TOKEN; req['Accept'] = 'application/json'
    JSON.parse(Net::HTTP.start(u.host, u.port, open_timeout: 5, read_timeout: 120) { |h| h.request(req) }.body)['MediaContainer']
  end

  # Sessions that load the server: anything transcoding, or actively playing/buffering.
  def busy_sessions
    (get('/status/sessions')['Metadata'] || []).select do |m|
      m['TranscodeSession'] || %w[playing buffering].include?(m.dig('Player', 'state'))
    end.map { |m| "#{m['title']} (#{m.dig('TranscodeSession', 'videoDecision') || m.dig('Player', 'state')})" }
  rescue StandardError => e
    ["plex unreachable: #{e.class}"]
  end

  def items(section_key, type)
    get("/library/sections/#{section_key}/all?type=#{type}")['Metadata'] || []
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV[0]
  when 'sessions' then puts PlexProbe.busy_sessions.inspect
  when 'shape'
    { 'movies' => [1, 1], 'episodes' => [2, 4] }.each do |name, (key, type)|
      its = PlexProbe.items(key, type)
      tally = its.map { |m| m.dig('Media', 0) }.compact.map { |md| [md['audioChannels'], md['audioCodec']] }.tally.sort_by { |_, n| -n }
      puts "#{name}: #{its.size}"; tally.first(12).each { |k, n| puts "  ch=#{k[0]} #{k[1]}: #{n}" }
    end
  end
end
