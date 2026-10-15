require 'spec_helper'

RSpec.describe Neutraliser::FFmpegError do
  # Shape of ffmpeg 7.1.1's real stderr copying a Matroska S_TEXT/WEBVTT track.
  let(:subtitle_stderr) do
    <<~STDERR
      ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers
        built with Apple clang version 16.0.0 (clang-1600.0.26.6)
        configuration: --prefix=/opt/homebrew/Cellar/ffmpeg/7.1.1_2 --enable-shared
        libavutil      59. 39.100 / 59. 39.100
      [matroska,webm @ 0x870408000] Unknown/unsupported AVCodecID S_TEXT/WEBVTT.
      [matroska,webm @ 0x870408000] Could not find codec parameters for stream 2 (Subtitle: none): unknown codec
      Consider increasing the value for the 'analyzeduration' (0) and 'probesize' (5000000) options
      Input #0, matroska,webm, from 'episode.mkv':
        Metadata:
          ENCODER         : Lavf61.7.100
        Duration: 00:22:02.02, start: -0.023000, bitrate: 86 kb/s
        Stream #0:2: Subtitle: none
      Stream mapping:
        Stream #0:2 -> #0:2 (copy)
      [matroska @ 0x87040b480] Subtitle codec 0 is not supported.
      [out#0/matroska @ 0x871430300] Could not write header (incorrect codec parameters ?): Function not implemented
      Conversion failed!
    STDERR
  end

  let(:permission_stderr) do
    <<~STDERR
      ffmpeg version 7.1.1 Copyright (c) 2000-2025 the FFmpeg developers
      Input #0, matroska,webm, from 'episode.mkv':
        Duration: 00:22:02.02, start: 0.000000, bitrate: 2000 kb/s
      [out#0/matroska @ 0x600002a1c000] Error opening output /tv/The Simpsons/Season 4/episode.tmp.mkv.
      Error opening output files: Permission denied
    STDERR
  end

  describe '.from_run' do
    let(:status) { instance_double(Process::Status, exitstatus: 1) }

    it 'keeps the message to the operation plus the line that says why, not the banner' do
      error = described_class.from_run('Normalization', permission_stderr, status)

      expect(error.message).to eq('Normalization failed (exit 1): Error opening output files: Permission denied')
      expect(error.reason).to eq(:not_writable)
      expect(error.stderr).to eq(permission_stderr)
    end

    it 'names an uncopyable subtitle even though the last line only says the header failed' do
      error = described_class.from_run('Normalization', subtitle_stderr, status)

      expect(error.reason).to eq(:unsupported_subtitle)
      expect(error.message).to eq(
        'Normalization failed (exit 1): [out#0/matroska] Could not write header (incorrect codec parameters ?): ' \
        'Function not implemented'
      )
    end

    it 'leaves unrecognised failures as :ffmpeg_error' do
      error = described_class.from_run('Measurement', "[mov,mp4 @ 0x1] moov atom not found\nfoo.mp4: Invalid data\n",
                                       status)

      expect(error.reason).to eq(:ffmpeg_error)
      expect(error.message).to eq('Measurement failed (exit 1): foo.mp4: Invalid data')
    end
  end

  describe '.last_meaningful_line' do
    it 'falls back to the last non-chatter line when nothing reads as an error' do
      expect(described_class.last_meaningful_line("ffmpeg version 7\nsomething odd happened\n\n"))
        .to eq('something odd happened')
    end

    it 'says so when there is no output at all' do
      expect(described_class.last_meaningful_line('')).to eq('no error output')
    end

    it 'truncates a runaway line' do
      expect(described_class.last_meaningful_line("Error: #{'x' * 1000}").length)
        .to eq(described_class::MAX_DETAIL_LENGTH + 3)
    end
  end

  it 'gives timeouts their own reason' do
    expect(Neutraliser::FFmpegTimeoutError.new('timed out').reason).to eq(:timeout)
  end
end

RSpec.describe 'integration: a real S_TEXT/WEBVTT subtitle track' do
  before do
    unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
      skip 'ffmpeg/ffprobe not available on PATH'
    end
  end

  # ffmpeg's Matroska muxer writes WebVTT as D_WEBVTT/SUBTITLES; mkvmerge
  # writes the newer S_TEXT/WEBVTT, which no ffmpeg release demuxes. Rewrite
  # the CodecID element in place (same byte length: shorter ID + an EBML Void
  # pad) to get the file the library actually holds.
  def write_stext_webvtt_mkv(dir)
    vtt = File.join(dir, 'subs.vtt')
    File.write(vtt, "WEBVTT\n\n00:00:00.500 --> 00:00:01.500\nHello\n")
    source = File.join(dir, 'source.mkv')
    system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-f', 'lavfi', '-i', 'sine=duration=2', '-i', vtt,
           '-map', '0', '-map', '1', '-c:a', 'aac', '-c:s', 'webvtt', '-write_crc32', '0', source,
           exception: true)
    data = File.binread(source)
    old = "\x86\x92D_WEBVTT/SUBTITLES".b
    data[data.index(old), old.bytesize] = "\x86\x8DS_TEXT/WEBVTT\xEC\x83\x00\x00\x00".b
    File.join(dir, 'episode.mkv').tap { |path| File.binwrite(path, data) }
  end

  it 'is found by the subtitle probe, and an encode that tries to copy it is classified, not dumped' do
    Dir.mktmpdir do |dir|
      input = write_stext_webvtt_mkv(dir)

      expect(Neutraliser::FFmpegWrapper.unsupported_subtitles(input)).to eq(['stream 1 (S_TEXT/WEBVTT)'])

      _, stderr, status = Open3.capture3('ffmpeg', '-hide_banner', '-y', '-i', input,
                                         '-map', '0', '-c', 'copy', File.join(dir, 'out.mkv'))
      error = Neutraliser::FFmpegError.from_run('Normalization', stderr, status)

      expect(error.reason).to eq(:unsupported_subtitle)
      expect(error.message.lines.count).to eq(1)
    end
  end
end
