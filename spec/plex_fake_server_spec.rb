require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'support/fake_plex_server'

# analyze-plex end to end against a fake Plex server that answers the way Plex
# does, with real ffmpeg reading synthetic clips over HTTP. The question it
# settles: does a Plex *TV* library give any results? (A show library's
# /all lists shows, which carry no Media; the episodes are at /all?type=4.)
RSpec.describe 'analyze-plex against a fake Plex server', :real_ffmpeg do
  let(:dir) { Dir.mktmpdir }
  let(:token) { 'fake-token-123' }
  let(:server) { FakePlexServer.new(libraries: libraries, token: token) }

  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
    allow(Neutraliser.logger).to receive(:log)
    server.start
  end

  after do
    server.stop
    FileUtils.remove_entry(dir)
  end

  # A short clip (read in full, so the run stays quick) at a known relative level.
  def clip(name, volume_db)
    File.join(dir, "#{name}.mkv").tap do |path|
      system('ffmpeg', '-hide_banner', '-v', 'error', '-y',
             '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=5:d=8',
             '-f', 'lavfi', '-i', 'sine=frequency=440:duration=8:sample_rate=48000',
             '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k',
             '-af', "volume=#{volume_db}dB", path) || raise('ffmpeg failed')
    end
  end

  def title(name, volume_db) = FakePlexServer::Title.new(title: name, path: clip(name, volume_db), duration_s: 8)

  # A 7.1 clip whose front six channels sit 4 dB under its two side surrounds. loudnorm counts the first
  # six channels only, so read alone it hears the quiet bed and leaves the loud sides out.
  def clip_surround(name)
    File.join(dir, "#{name}.mkv").tap do |path|
      graph = '[0:a]asplit=2[q][l];[q]volume=-10dB,asplit=6[c0][c1][c2][c3][c4][c5];[l]volume=-6dB,asplit=2[s0][s1];' \
              '[c0][c1][c2][c3][c4][c5][s0][s1]join=inputs=8:channel_layout=7.1:' \
              'map=0.0-FL|1.0-FR|2.0-FC|3.0-LFE|4.0-BL|5.0-BR|6.0-SL|7.0-SR'
      system('ffmpeg', '-hide_banner', '-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=8',
             '-filter_complex', graph, '-c:a', 'flac', path) || raise('ffmpeg failed')
    end
  end

  # Integrated loudness over every channel, as ffmpeg's own ebur128 reads it (not the loudnorm the tool uses).
  def ebur128_i(path)
    _, err, = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-i', path, '-af', 'ebur128', '-f', 'null', '-')
    err.scan(/I:\s+(-?\d+\.\d)\s+LUFS/).last.first.to_f
  end

  let(:libraries) do
    [
      FakePlexServer::Library.new(key: '1', title: 'Films', type: 'movie',
                                  items: [title('Quiet Film', -14)]),
      FakePlexServer::Library.new(key: '2', title: 'Shows', type: 'show',
                                  items: [['Some Show', 1, 1, title('Pilot', -14)],
                                          ['Some Show', 1, 2, title('Second', 8)]])
    ]
  end

  def analyse(library_name: nil, full: false)
    Dir.chdir(dir) do
      Neutraliser::PlexAnalyzer.new(server_url: server.url, token: token, library_name: library_name,
                                    output_format: 'json', full: full).analyze
    end
    report = Dir.glob(File.join(dir, 'plex_audio_analysis_*.json')).max
    report ? JSON.parse(File.read(report)).fetch('results') : []
  end

  it 'measures a movie library' do
    results = analyse(library_name: 'Films')

    expect(results.map { |r| r['title'] }).to eq(['Quiet Film'])
    expect(results.first['content_type']).to eq('movie')
    expect(results.first['adjustment_type']).to eq('Too Quiet')
  end

  it "measures a TV library's episodes, not just the shows" do
    results = analyse(library_name: 'Shows')

    expect(results.size).to eq(2)
    expect(results.map { |r| r['content_type'] }.uniq).to eq(['tv'])
    expect(results.map { |r| r['adjustment_type'] }).to contain_exactly('Too Quiet', 'Too Loud')
  end

  it 'names an episode by its show, season and episode number' do
    titles = analyse(library_name: 'Shows').map { |r| r['title'] }

    expect(titles).to contain_exactly('Some Show S01E01 Pilot', 'Some Show S01E02 Second')
  end

  context 'with a 7.1 title whose loud channels are the side surrounds' do
    let(:surround) { FakePlexServer::Title.new(title: 'Wide Film', path: clip_surround('wide'), duration_s: 8, channels: 8) }
    let(:libraries) { [FakePlexServer::Library.new(key: '1', title: 'Films', type: 'movie', items: [surround])] }

    it 'reads it with all eight channels, so it is not triaged too quiet' do
      result = analyse.first

      expect(result['current_level']).to be_within(0.5).of(ebur128_i(surround.path))
      expect(result['adjustment_type']).to eq('OK')
    end

    it 'reads each sampled window with all eight channels too' do
      stub_const('Neutraliser::PlexAnalyzer::READ_IN_FULL_BELOW_S', 5)
      result = analyse.first

      expect(result['measured']).to eq('sampled')
      expect(result['current_level']).to be_within(0.5).of(ebur128_i(surround.path))
    end

    it 'takes the channel count from the track, not from what Plex lists' do
      surround.channels = 2

      expect(analyse.first['adjustment_type']).to eq('OK')
    end
  end

  # A sweep levels the default-flagged track, which here is the second stream, 6 dB louder than the first.
  context 'with a title whose default audio track is not the first' do
    let(:two_tracks) do
      path = File.join(dir, 'two.mkv')
      system('ffmpeg', '-hide_banner', '-v', 'error', '-y',
             '-f', 'lavfi', '-i', 'sine=frequency=440:duration=8:sample_rate=48000',
             '-filter_complex', '[0:a]volume=-20dB[a0];[0:a]volume=-8dB[a1]',
             '-map', '[a0]', '-map', '[a1]', '-c:a', 'flac', '-disposition:a:0', '0', '-disposition:a:1', 'default', path) || raise('ffmpeg failed')
      FakePlexServer::Title.new(title: 'Dubbed Film', path: path, duration_s: 8, channels: 2)
    end
    let(:libraries) { [FakePlexServer::Library.new(key: '1', title: 'Films', type: 'movie', items: [two_tracks])] }

    it 'measures that track' do
      _, err, = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-i', two_tracks.path, '-map', '0:a:1',
                               '-af', 'ebur128', '-f', 'null', '-')
      default_level = err.scan(/I:\s+(-?[\d.]+) LUFS/).last.first.to_f

      expect(analyse.first['current_level']).to be_within(0.5).of(default_level)
    end
  end

  # Plex promises the whole file and closes the connection part-way. ffmpeg exits 0 on that and loudnorm
  # prints the level of whatever it got, so only the length read can tell it from a whole title.
  context 'when Plex closes the connection part-way through a title' do
    let(:cut) { FakePlexServer::Title.new(title: 'Cut Film', path: clip('cut', -14), duration_s: 8, sends_share: 0.3) }
    let(:libraries) { [FakePlexServer::Library.new(key: '1', title: 'Films', type: 'movie', items: [cut])] }

    it 'leaves a whole-title read out rather than reporting it as an exact level' do
      expect(analyse).to be_empty
      expect(Neutraliser.logger).to have_received(:log).with(/Cut Film.*Plex sent only \d+s of 8s/)
    end

    it 'leaves it out of a --full run too' do
      stub_const('Neutraliser::PlexAnalyzer::READ_IN_FULL_BELOW_S', 5) # only --full reads this title end to end

      expect(analyse(full: true)).to be_empty
    end

    it 'does not count a cut-short window towards a sampled estimate' do
      stub_const('Neutraliser::PlexAnalyzer::READ_IN_FULL_BELOW_S', 5)

      expect(analyse).to be_empty
      expect(Neutraliser.logger).to have_received(:log).with(/unreadable window.*Plex sent only/).at_least(:once)
    end

    it 'still reports a title that arrives whole' do
      cut.sends_share = nil

      expect(analyse.map { |r| r['measured'] }).to eq(['full'])
    end
  end

  it 'covers movies and TV in one run' do
    expect(analyse.map { |r| r['content_type'] }).to contain_exactly('movie', 'tv', 'tv')
  end
end
