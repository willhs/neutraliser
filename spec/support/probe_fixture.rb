# ffprobe's JSON for a made-up file, so specs set up a file's facts the way ffprobe reports them
# (strings for numbers, "N/A" for an unknown bit rate) and read them back through Source.
#
#   source = ProbeFixture.source('film.mkv', audio: [ProbeFixture.audio(codec: 'eac3', channels: 6, default: true)])
#
# `stub_probe` is for specs that run code which builds its own Source from a path (Processor,
# Report): the one ffprobe subprocess answers with the fixture instead.
module ProbeFixture
  module_function

  # One audio stream. tags are the stream's own tags (language and title included).
  def audio(codec: 'aac', channels: 2, layout: nil, language: nil, title: nil, default: false, bit_rate: '128000',
            sample_rate: '48000', profile: nil, tags: {}, dispositions: [], handler_name: nil)
    stream = { 'codec_type' => 'audio', 'codec_name' => codec, 'channels' => channels,
               'channel_layout' => layout || { 1 => 'mono', 2 => 'stereo', 6 => '5.1(side)', 8 => '7.1' }.fetch(channels, 'stereo'),
               'sample_rate' => sample_rate, 'bit_rate' => bit_rate }
    stream['profile'] = profile if profile
    stream_tags = tags.dup
    stream_tags['language'] = language if language
    stream_tags['title'] = title if title
    stream_tags['handler_name'] = handler_name if handler_name
    stream['tags'] = stream_tags unless stream_tags.empty?
    stream['disposition'] = dispositions.to_h { |flag| [flag.to_s, 1] }.merge('default' => default ? 1 : 0)
    stream
  end

  # The whole file. audio: the audio streams (a default stereo AAC one if none are given; pass [] for a
  # file with no audio). subtitles: codec names, nil for one ffmpeg has no codec for.
  def json(audio: [ProbeFixture.audio], video: 1, subtitles: [], attachments: 0, chapters: 0, duration: 120.0,
           format_name: 'matroska,webm', container_tags: {}, attached_picture: false)
    streams = Array.new(video) { |i| { 'codec_type' => 'video', 'codec_name' => 'h264', 'disposition' => { 'attached_pic' => i.zero? && attached_picture ? 1 : 0 } } }
    streams += audio
    streams += subtitles.map { |codec| { 'codec_type' => 'subtitle', 'codec_name' => codec }.compact }
    streams += Array.new(attachments) { { 'codec_type' => 'attachment', 'codec_name' => 'ttf' } }
    streams.each_with_index { |stream, i| stream['index'] = i }
    format = { 'format_name' => format_name }
    format['duration'] = duration.to_s if duration
    format['tags'] = container_tags unless container_tags.empty?
    JSON.generate('streams' => streams, 'format' => format, 'chapters' => Array.new(chapters) { |i| { 'id' => i } })
  end

  def source(path = 'film.mkv', stderr: '', **fixture)
    Neutraliser::Source.from_ffprobe(path, json(**fixture), stderr)
  end

  # Same fixture options, as the primary track alone (what code that takes one track wants).
  def track(**audio_options)
    source(audio: [audio(**audio_options)]).primary_track
  end

  # The `-v info` stderr line for a subtitle stream ffmpeg has no codec for.
  def unknown_subtitle_stderr(*codec_ids)
    codec_ids.map { |id| "[matroska,webm @ 0x1] Unknown/unsupported AVCodecID #{id}.\n" }.join
  end
end

module ProbeStubs
  # Every ffprobe run answers with this file (or, with a hash, with the file for that path).
  def stub_probe(stderr: '', for_path: nil, **fixture)
    allow(Neutraliser::FFmpegWrapper).to receive(:probe_file) do |path|
      raise Neutraliser::FFmpegError, 'File probe failed (exit 1): No such file' if for_path && path != for_path

      [ProbeFixture.json(**fixture), stderr]
    end
  end

  # Every file is a plain stereo file carrying this Stamp (nil: none) in its audio tags.
  def stub_stamp(stamp) = stub_stamps { stamp }

  # The same, with the stamp chosen per path by the block.
  def stub_stamps
    allow(Neutraliser::FFmpegWrapper).to receive(:probe_file) do |path|
      stamp = yield(path)
      [ProbeFixture.json(audio: [ProbeFixture.audio(tags: stamp ? stamp.to_tags : {})]), '']
    end
  end

  # Each file answers with its own fixture, found by file name.
  def stub_probes(by_name)
    allow(Neutraliser::FFmpegWrapper).to receive(:probe_file) do |path|
      [ProbeFixture.json(**by_name.fetch(File.basename(path))), '']
    end
  end

  # ffprobe exits non-zero for this path: a corrupt or half-written file.
  def stub_unreadable_probe
    allow(Neutraliser::FFmpegWrapper).to receive(:probe_file)
      .and_raise(Neutraliser::FFmpegError, 'File probe failed (exit 1): Invalid data found when processing input')
  end
end

RSpec.configure do |config|
  config.include ProbeStubs
end
