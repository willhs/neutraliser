require 'json'
require 'socket'
require 'uri'

# A small stand-in for the parts of a Plex Media Server that `analyze-plex` uses,
# behaving the way Plex does (not the way the analyser would like it to):
#
#   GET /library/sections                  the libraries
#   GET /library/sections/N/all            a movie library lists movies, with Media
#                                          a show library lists SHOWS, with no Media
#   GET /library/sections/N/all?type=4     a show library's episodes, with Media
#   GET /library/parts/ID/file             the media bytes, with Range support
#
# Every request needs the token as `X-Plex-Token`; anything else is a 401, as on
# a real server. `requests` records what was asked, so a spec can see the path.
class FakePlexServer
  Title = Struct.new(:title, :path, :duration_s, keyword_init: true)

  Library = Struct.new(:key, :title, :type, :items, keyword_init: true)

  attr_reader :token, :requests

  # libraries: [Library]; for a 'show' library each item is a
  # [show_title, season, episode, Title] tuple.
  def initialize(libraries:, token: 'fake-token')
    @libraries = libraries
    @token = token
    @requests = []
    @parts = {}
    @lock = Mutex.new
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def start
    @server = TCPServer.new('127.0.0.1', 0)
    @thread = Thread.new do
      loop { Thread.new(@server.accept) { |client| handle(client) } }
    rescue IOError, Errno::EBADF
      nil
    end
    self
  end

  def stop
    @server&.close
    @thread&.join(1)
  end

  private

  def handle(client)
    request_line = client.gets or return
    method, target, = request_line.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(':', 2)
      headers[name.downcase] = value.to_s.strip
    end
    @lock.synchronize { @requests << target } unless target.start_with?('/library/parts/')

    return respond(client, 401, 'text/plain', 'Unauthorized') unless headers['x-plex-token'] == token
    return respond(client, 405, 'text/plain', '') unless %w[GET HEAD].include?(method)

    route(client, URI.parse(target), headers)
  rescue Errno::EPIPE, Errno::ECONNRESET
    nil
  ensure
    client.close
  end

  def route(client, uri, headers)
    query = URI.decode_www_form(uri.query.to_s).to_h
    case uri.path
    when '/library/sections' then json(client, sections)
    when %r{\A/library/sections/(\d+)/all\z} then json(client, section_contents(Regexp.last_match(1), query['type']))
    when %r{\A/library/parts/(\d+)/file\z} then media(client, Regexp.last_match(1).to_i, headers['range'])
    else respond(client, 404, 'text/plain', 'Not found')
    end
  end

  def sections
    directories = @libraries.map { |lib| { 'key' => lib.key, 'title' => lib.title, 'type' => lib.type } }
    { 'MediaContainer' => { 'size' => directories.size, 'Directory' => directories } }
  end

  def section_contents(key, type_filter)
    library = @libraries.find { |lib| lib.key == key } or return { 'MediaContainer' => { 'size' => 0 } }

    metadata =
      if library.type == 'movie'
        library.items.map { |movie| movie_entry(movie) }
      elsif type_filter == '4'
        library.items.map { |show, season, episode, title| episode_entry(show, season, episode, title) }
      else
        library.items.map { |show, *| show }.uniq.map { |name| { 'type' => 'show', 'title' => name } }
      end
    { 'MediaContainer' => { 'size' => metadata.size, 'Metadata' => metadata } }
  end

  def movie_entry(title) = { 'type' => 'movie', 'title' => title.title }.merge(media_for(title))

  def episode_entry(show, season, episode, title)
    { 'type' => 'episode', 'title' => title.title, 'grandparentTitle' => show,
      'parentIndex' => season, 'index' => episode }.merge(media_for(title))
  end

  def media_for(title)
    part_id = @lock.synchronize { @parts.key(title.path) || (@parts.size + 1).tap { |id| @parts[id] = title.path } }
    { 'duration' => (title.duration_s * 1000).to_i,
      'Media' => [{ 'Part' => [{ 'key' => "/library/parts/#{part_id}/file" }] }] }
  end

  def media(client, part_id, range)
    path = @lock.synchronize { @parts[part_id] } or return respond(client, 404, 'text/plain', 'Not found')

    data = File.binread(path)
    if range && (match = range.match(/bytes=(\d+)-(\d*)/))
      first = match[1].to_i
      last = match[2].empty? ? data.bytesize - 1 : [match[2].to_i, data.bytesize - 1].min
      respond(client, 206, 'video/x-matroska', data.byteslice(first..last),
              'Content-Range' => "bytes #{first}-#{last}/#{data.bytesize}")
    else
      respond(client, 200, 'video/x-matroska', data)
    end
  end

  def json(client, body) = respond(client, 200, 'application/json', JSON.generate(body))

  def respond(client, status, type, body, extra = {})
    head = ["HTTP/1.1 #{status} X", "Content-Type: #{type}", "Content-Length: #{body.bytesize}",
            'Accept-Ranges: bytes', 'Connection: close']
    extra.each { |name, value| head << "#{name}: #{value}" }
    client.write("#{head.join("\r\n")}\r\n\r\n")
    client.write(body)
  end
end
