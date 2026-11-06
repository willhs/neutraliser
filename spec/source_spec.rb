require 'spec_helper'
require 'open3'

RSpec.describe Neutraliser::Source do
  def audio(**options) = ProbeFixture.audio(**options)

  describe 'the audio tracks' do
    it 'reads ffprobe json by field name, with the position among audio streams as the index' do
      # Video is stream 0, so the first audio stream is container stream 1 but audio index 0.
      source = described_class.from_ffprobe('test.mkv', {
        streams: [
          { index: 0, codec_type: 'video', codec_name: 'h264' },
          { index: 1, codec_type: 'audio', codec_name: 'ac3', sample_rate: '48000', channels: 6, channel_layout: '5.1(side)', bit_rate: '640000' },
          { index: 2, codec_type: 'audio', codec_name: 'aac', sample_rate: '44100', channels: 2, bit_rate: '256000' }
        ]
      }.to_json)

      expect(source.audio_tracks).to eq([
                                          { index: 0, stream_index: 1, channels: 6, channel_layout: '5.1(side)', codec: 'ac3', profile: nil, title: nil,
                                            handler_name: nil, language: nil, default: false, dispositions: [], bit_rate: 640_000, sample_rate: 48_000, tags: {} },
                                          { index: 1, stream_index: 2, channels: 2, channel_layout: nil, codec: 'aac', profile: nil, title: nil,
                                            handler_name: nil, language: nil, default: false, dispositions: [], bit_rate: 256_000, sample_rate: 44_100, tags: {} }
                                        ])
    end

    it 'flags the default-disposition track and keeps the preserved dispositions' do
      source = ProbeFixture.source(audio: [audio, audio(default: true, dispositions: %i[hearing_impaired forced])])

      expect(source.audio_tracks.map { |t| t[:default] }).to eq([false, true])
      expect(source.audio_tracks.last[:dispositions]).to eq(%w[forced hearing_impaired])
    end

    it 'reads the codec profile and track title, treating "unknown" as no profile' do
      source = ProbeFixture.source(audio: [audio(codec: 'truehd', channels: 8, profile: 'Dolby TrueHD + Dolby Atmos', title: 'TrueHD Atmos 7.1'),
                                           audio(codec: 'eac3', channels: 6, profile: 'unknown')])

      expect(source.audio_tracks.map { |t| t.slice(:profile, :title) })
        .to eq([{ profile: 'Dolby TrueHD + Dolby Atmos', title: 'TrueHD Atmos 7.1' }, { profile: nil, title: nil }])
    end

    it 'treats an absent or N/A bit_rate as nil rather than a made-up number' do
      absent = described_class.from_ffprobe('a.mkv', { streams: [{ codec_type: 'audio', codec_name: 'flac', sample_rate: '48000', channels: 6 }] }.to_json)
      not_available = ProbeFixture.source(audio: [audio(bit_rate: 'N/A')])

      expect(absent.audio_tracks.first).to include(codec: 'flac', channels: 6, bit_rate: nil, sample_rate: 48_000)
      expect(not_available.audio_tracks.first[:bit_rate]).to be_nil
    end

    it 'keeps the stream tags, which carry the stamp and any BPS record' do
      source = ProbeFixture.source(audio: [audio(tags: { 'BPS' => '192000' }, language: 'eng')])

      expect(source.audio_tracks.first[:tags]).to eq('BPS' => '192000', 'language' => 'eng')
    end
  end

  describe '#primary_track' do
    it 'is the default-disposition track, else the first' do
      expect(ProbeFixture.source(audio: [audio, audio(default: true)]).primary_track).to include(index: 1)
      expect(ProbeFixture.source(audio: [audio, audio]).primary_track).to include(index: 0)
    end

    it 'prefers the first English track over the first track when none is flagged default' do
      source = ProbeFixture.source(audio: [audio(language: 'spa'), audio(language: 'fra'), audio(language: 'eng')])

      expect(source.primary_track).to include(index: 2, language: 'eng')
    end

    it 'lets the default flag beat the English fallback' do
      source = ProbeFixture.source(audio: [audio(language: 'spa', default: true), audio(language: 'eng')])

      expect(source.primary_track).to include(index: 0)
    end

    it 'is the same track object the track list holds, so callers can tell which one it is' do
      source = ProbeFixture.source(audio: [audio, audio(default: true)])

      expect(source.audio_tracks).to include(equal(source.primary_track))
    end
  end

  describe 'a file ffprobe reads but finds no audio in' do
    let(:source) { ProbeFixture.source(audio: []) }

    it 'has no audio, and says so in one place' do
      expect(source.audio?).to be(false)
      expect(source.audio_tracks).to eq([])
    end

    it 'answers the explicitly-marked unknown track, never a made-up stereo one that looks real' do
      expect(source.primary_track).to equal(described_class::UNKNOWN_AUDIO_TRACK)
      expect(source.primary_track[:unknown]).to be(true)
    end
  end

  describe 'the rest of the facts' do
    it 'counts each kind of stream and the chapters' do
      source = ProbeFixture.source(audio: [audio, audio], video: 2, subtitles: %w[subrip ass], attachments: 3, chapters: 4)

      expect(source.stream_counts).to eq(video: 2, audio: 2, subtitle: 2, attachment: 3, chapter: 4)
    end

    it 'reads the duration, nil when the container reports none or an unusable one' do
      expect(ProbeFixture.source(duration: 12.3).duration).to eq(12.3)
      expect(ProbeFixture.source(duration: nil).duration).to be_nil
      expect(described_class.from_ffprobe('a.mkv', { streams: [], format: { duration: '0.000000' } }.to_json).duration).to be_nil
    end

    it 'knows MP4 bytes from the format name, whatever the file is called' do
      expect(ProbeFixture.source('fake.mkv', format_name: 'mov,mp4,m4a,3gp,3g2,mj2').mp4_family?).to be(true)
      expect(ProbeFixture.source('film.mkv', format_name: 'matroska,webm').mp4_family?).to be(false)
    end

    it 'reports cover art and the container tag names (lower-cased)' do
      plain = ProbeFixture.source
      covered = ProbeFixture.source(attached_picture: true, container_tags: { 'Title' => 'x', 'ARTIST' => 'y' })

      expect(plain.attached_picture?).to be(false)
      expect(covered.attached_picture?).to be(true)
      expect(covered.container_tag_names).to contain_exactly('title', 'artist')
    end

    it 'names subtitle streams ffmpeg has no codec for, with the Matroska codec ID' do
      source = ProbeFixture.source(subtitles: [nil, 'subrip', nil],
                                   stderr: ProbeFixture.unknown_subtitle_stderr('S_TEXT/WEBVTT', 'S_TEXT/FOO'))

      expect(source.unsupported_subtitles).to eq(['stream 2 (S_TEXT/WEBVTT)', 'stream 4 (S_TEXT/FOO)'])
    end

    it 'finds nothing unsupported when every subtitle has a codec' do
      expect(ProbeFixture.source(subtitles: ['hdmv_pgs_subtitle']).unsupported_subtitles).to eq([])
    end
  end

  describe '#stamp' do
    let(:stamped) do
      Neutraliser::Stamp.now(profile: 'night', mode: 'dynamic', gain_db: nil, source_codec: 'aac', source_bitrate: nil,
                             measured_i: nil, measured_tp: nil, measured_lra: nil)
    end

    it "reads the stamp from the primary audio stream's tags" do
      source = ProbeFixture.source(audio: [audio, audio(default: true, tags: stamped.to_tags)],
                                   container_tags: { 'NEUTRALISER_PROFILE' => 'livingroom' })

      expect(source.stamp).to have_attributes(profile: 'night', mode: 'dynamic')
    end

    it 'falls back to the container tags (all MP4 keeps)' do
      source = ProbeFixture.source(audio: [audio(language: 'eng')],
                                   container_tags: { 'NEUTRALISER_PROFILE' => 'livingroom', 'NEUTRALISER_GAIN_DB' => '3.20' })

      expect(source.stamp).to have_attributes(profile: 'livingroom', gain_db: 3.2)
    end

    it 'is nil for an unstamped file, one with no audio, or one that could not be probed' do
      expect(ProbeFixture.source(audio: [audio(tags: { 'a' => 'b' })]).stamp).to be_nil
      expect(ProbeFixture.source(audio: []).stamp).to be_nil

      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Neutraliser::FFmpegError, 'bad')
      expect(described_class.new('bad.mkv').stamp).to be_nil
    end
  end

  describe 'probing' do
    before do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_return([ProbeFixture.json(subtitles: ['subrip']), ''])
    end

    it 'does not run ffprobe until a fact is asked for' do
      described_class.new('film.mkv')

      expect(Neutraliser::FFmpegWrapper).not_to have_received(:probe_file)
    end

    it 'runs it once, however many facts are asked for' do
      source = described_class.new('film.mkv')

      source.audio_tracks
      source.primary_track
      source.stream_counts
      source.duration
      source.stamp
      source.unsupported_subtitles
      source.mp4_family?

      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).with('film.mkv').once
    end

    it 'shares the probe with a copy of the file (a staged working copy), which is read from its own path' do
      source = described_class.new('/nas/film.mkv')
      source.audio_tracks

      copy = source.for_copy('/tmp/stage/film.mkv')

      expect(copy.path).to eq('/tmp/stage/film.mkv')
      expect(copy.primary_track).to equal(source.primary_track)
      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once
    end

    it 'keeps a failed probe as the answer: every fact raises it, and ffprobe still ran once' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file)
        .and_raise(Neutraliser::FFmpegError.new('File probe failed (exit 1): Invalid data', reason: :ffmpeg_error))
      source = described_class.new('bad.mkv')

      expect { source.audio_tracks }.to raise_error(Neutraliser::FFmpegError, /Invalid data/)
      expect { source.duration }.to raise_error(Neutraliser::FFmpegError, /Invalid data/)
      expect(source.readable?).to be(false)
      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once
    end

    it 'is readable when ffprobe read the file' do
      expect(described_class.new('film.mkv').readable?).to be(true)
    end

    it 'does not call a hang unreadable: the timeout surfaces, to be retried' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      expect { described_class.new('slow.mkv').readable? }.to raise_error(Neutraliser::FFmpegTimeoutError)
    end

    it 'treats output that is not json as an unreadable file, not as a file with no audio' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_return(['not json', ''])
      source = described_class.new('odd.mkv')

      expect(source.readable?).to be(false)
      expect { source.audio_tracks }.to raise_error(Neutraliser::FFmpegError, /could not be read/)
    end

    it 'lets a missing ffprobe through as the environment problem it is' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Errno::ENOENT, 'ffprobe')

      expect { described_class.new('film.mkv').audio_tracks }.to raise_error(Errno::ENOENT)
    end
  end

  # The one place the real ffprobe is asked, so a fixture can't hide a quirk of its json.
  describe 'against a real file', :real_ffmpeg do
    before do
      skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
    end

    it 'reads the tracks, counts, duration, container and stamp of a generated mkv' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'film.mkv')
        system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=3',
               '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=3:sample_rate=48000:amplitude=0.05',
               '-f', 'lavfi', '-i', 'sine=frequency=330:duration=3:sample_rate=44100',
               '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'libx264', '-preset', 'ultrafast',
               '-c:a:0', 'ac3', '-ac:a:0', '6', '-c:a:1', 'aac',
               '-metadata:s:a:0', 'language=spa', '-metadata:s:a:1', 'language=eng',
               '-metadata:s:a:1', 'NEUTRALISER_PROFILE=night', '-metadata', 'title=Film',
               '-disposition:a:0', '0', '-disposition:a:1', 'default', path, exception: true)

        source = described_class.new(path)

        expect(source.audio_tracks.map { |t| [t[:index], t[:codec], t[:channels], t[:language], t[:sample_rate]] })
          .to eq([[0, 'ac3', 6, 'spa', 48_000], [1, 'aac', 1, 'eng', 44_100]])
        expect(source.primary_track).to include(index: 1, codec: 'aac', default: true)
        expect(source.stream_counts).to eq(video: 1, audio: 2, subtitle: 0, attachment: 0, chapter: 0)
        expect(source.duration).to be_within(0.5).of(3.0)
        expect(source.mp4_family?).to be(false)
        expect(source.unsupported_subtitles).to eq([])
        expect(source.stamp).to have_attributes(profile: 'night')
        expect(described_class.new(File.join(dir, 'missing.mkv')).readable?).to be(false)
      end
    end
  end
end
