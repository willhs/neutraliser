require 'spec_helper'
require 'fileutils'
require 'json'
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
    unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
      skip 'ffmpeg/ffprobe not available on PATH'
    end
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

  let(:libraries) do
    [
      FakePlexServer::Library.new(key: '1', title: 'Films', type: 'movie',
                                  items: [title('Quiet Film', -14)]),
      FakePlexServer::Library.new(key: '2', title: 'Shows', type: 'show',
                                  items: [['Some Show', 1, 1, title('Pilot', -14)],
                                          ['Some Show', 1, 2, title('Second', 8)]])
    ]
  end

  def analyse(library_name: nil)
    Dir.chdir(dir) do
      Neutraliser::PlexAnalyzer.new(server_url: server.url, token: token, library_name: library_name,
                                    output_format: 'json').analyze
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

  it 'covers movies and TV in one run' do
    expect(analyse.map { |r| r['content_type'] }).to contain_exactly('movie', 'tv', 'tv')
  end
end
