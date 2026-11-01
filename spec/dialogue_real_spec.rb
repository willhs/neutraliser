# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'digest'
require 'json'
require 'fileutils'
require_relative 'support/lra_fixture'

# The dialogue figures with a real ffmpeg: generated 5.1 and stereo clips, `report --measure` and `rate-sample`
# through the CLI. The centre-channel figure is checked against ffmpeg's own ebur128 on that channel, and
# nothing in the library may change.
RSpec.describe 'Dialogue estimate, read-only', :real_ffmpeg do
  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
  end

  let(:dir) { Dir.mktmpdir }
  let(:library) { File.join(dir, 'library') }

  after { FileUtils.rm_rf(dir) }

  def ffmpeg!(*args) = system('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args, exception: true)

  # 5.1 AC-3 with noise only in the centre at -27ish LUFS and louder noise on every other channel, so the
  # centre is the "dialogue" and the programme sits well above it. dialnorm: the value to write (1..31, written as -N).
  def surround_clip(path, dialnorm: nil)
    FileUtils.mkdir_p(File.dirname(path))
    options = dialnorm ? ['-dialnorm', (-dialnorm).to_s] : []
    ffmpeg!('-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=8:rate=10',
            '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=8:sample_rate=48000:amplitude=0.05',
            '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=8:sample_rate=48000:amplitude=0.2',
            '-filter_complex', '[1:a]pan=5.1|c2=c0[dia];[2:a]pan=5.1|c0=c0|c1=c0|c4=c0|c5=c0[fx];[dia][fx]amix=inputs=2:normalize=0[mix]',
            '-map', '0:v', '-map', '[mix]', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'ac3', '-b:a', '448k',
            *options, path)
  end

  def stereo_clip(path)
    FileUtils.mkdir_p(File.dirname(path))
    ffmpeg!('-f', 'lavfi', '-i', 'color=c=blue:size=64x64:duration=8:rate=10',
            '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=8:sample_rate=48000:amplitude=0.1',
            '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-ac', '2', path)
  end

  # Integrated loudness of the centre channel as ffmpeg's ebur128 reads it (not the loudnorm the tool uses).
  def centre_lufs(path)
    _, stderr, = Open3.capture3('ffmpeg', '-hide_banner', '-nostats', '-drc_scale', '0', '-i', path, '-map', '0:a:0',
                                '-af', 'pan=mono|c0=c2,ebur128', '-f', 'null', '-')
    stderr[/Integrated loudness:\s+I:\s+(-?\d+\.\d)/m, 1].to_f
  end

  def snapshot(root)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: root).sort.to_h do |relative|
      path = File.join(root, relative)
      [relative, File.file?(path) ? Digest::SHA256.file(path).hexdigest : :dir]
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  before do
    surround_clip(File.join(library, 'Film (2020)', 'Film.mkv'), dialnorm: 24)
    stereo_clip(File.join(library, 'Show S01E01.mkv'))
  end

  it 'estimates the centre channel within half an LU of ebur128, reads the dialnorm, and changes nothing' do
    film = File.join(library, 'Film (2020)', 'Film.mkv')
    before = snapshot(library)

    json = JSON.parse(capture_stdout { Neutraliser::CLI.start(['report', library, '--measure', '--format', 'json']) })

    expect(snapshot(library)).to eq(before)
    dialogue = json['files'].find { |file| file['file'] == film }['dialogue']
    expect(dialogue).to include('method' => 'centre_channel', 'confidence' => 'medium', 'dialnorm' => -24)
    expect(dialogue['dialogue_i']).to be_within(0.5).of(centre_lufs(film))
    expect(dialogue['loudness_above_dialogue']).to be > 4.0
    expect(dialogue['loudness_above_dialogue']).to be_within(0.01).of(dialogue['programme_i'] - dialogue['dialogue_i'])
  end

  it 'gives stereo no figure, with the reason, and counts it apart' do
    json = JSON.parse(capture_stdout { Neutraliser::CLI.start(['report', library, '--measure', '--format', 'json']) })

    show = json['files'].find { |file| file['file'].end_with?('Show S01E01.mkv') }
    expect(show['dialogue']).to include('dialogue_i' => nil, 'reason' => 'stereo, no centre channel')
    expect(json.dig('summary', 'dialogue_remote_free_rate')).to include('judged' => 1, 'not_judged' => 1)
    expect(json.dig('summary', 'remote_free_rate')).to include('judged' => 2)
  end

  it 'is absent without --measure and with --no-dialogue' do
    plain = capture_stdout { Neutraliser::CLI.start(['report', library]) }
    off = capture_stdout { Neutraliser::CLI.start(['report', library, '--measure', '--no-dialogue']) }

    expect(plain).not_to include('Dialogue')
    expect(off).to include('Remote-free rate:')
    expect(off).not_to include('Dialogue')
  end

  it 'carries the source dialnorm through rate-sample, and leaves the library alone' do
    before = snapshot(library)
    work = File.join(dir, 'scratch')
    FileUtils.mkdir_p(work)

    out = capture_stdout { Neutraliser::CLI.start(['rate-sample', library, '--sample', '2', '--seed', '1', '--work-dir', work]) }

    expect(snapshot(library)).to eq(before)
    film_line = out.lines.find { |line| line.start_with?('library/Film') }
    expect(film_line).to include('dialogue -', 'centre channel, medium confidence', 'dialnorm -24')
    expect(out.lines.find { |line| line.start_with?('library/Show') }).to include('dialogue: n/a (stereo, no centre channel)')
    expect(out).to include('Dialogue-anchored remote-free rate:', 'Loudness above dialogue: median')
  end
end
