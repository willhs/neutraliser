require 'spec_helper'

# The plan is pure computation: argv and expected shape, no ffmpeg. The real-ffmpeg
# check of the same behaviour is spec/round_trip_spec.rb.
RSpec.describe Neutraliser::RemuxPlan do
  let(:stamp) do
    Neutraliser::Stamp.now(profile: 'livingroom', mode: 'linear', gain_db: -1.5, source_codec: 'aac', source_bitrate: nil,
                           measured_i: -18.5, measured_tp: -2.1, measured_lra: 8.3)
  end
  let(:codec) { { encoder: 'ac3', bitrate: 448_000, dialnorm: -27 } }

  def plan(tracks, path: 'film.mkv', output: 'out.mkv', keep_original: false, container: File.extname(output), mdta: true, **fixture)
    source = ProbeFixture.source(path, audio: tracks, **fixture)
    described_class.new(source, output, container: container, mdta: mdta, filter: 'volume=-1.5dB', codec_decision: codec,
                                        stamp: stamp, keep_original: keep_original)
  end

  def pairs(plan) = plan.argv.each_cons(2).to_a

  def values(plan, flag) = pairs(plan).select { |a, _| a == flag }.map(&:last)

  let(:tracks) do
    [ProbeFixture.audio(title: 'Commentary', language: 'eng'),
     ProbeFixture.audio(codec: 'ac3', channels: 6, title: 'English', language: 'eng', default: true),
     ProbeFixture.audio(title: 'French', language: 'fre')]
  end

  it 'filters the primary track, encodes it in place and stream-copies the others around it' do
    plan = plan(tracks)

    expect(plan.argv.first).to eq('ffmpeg')
    expect(plan.argv.last).to eq('out.mkv')
    expect(values(plan, '-filter_complex')).to eq(['[0:a:1]volume=-1.5dB[norm]'])
    expect(values(plan, '-map')).to eq(['0:v?', '0:a:0', '[norm]', '0:a:2', '0:s?', '0:t?'])
    expect(pairs(plan)).to include(['-c:a:0', 'copy'], ['-c:a:1', 'ac3'], ['-b:a:1', '448k'], ['-dialnorm:a:1', '-27'],
                                   ['-c:a:2', 'copy'])
  end

  it 'maps every output audio stream back to its source stream' do
    expect(values(plan(tracks), '-map_metadata:s:a:0') + values(plan(tracks), '-map_metadata:s:a:1') +
           values(plan(tracks), '-map_metadata:s:a:2')).to eq(['0:s:a:0', '0:s:a:1', '0:s:a:2'])
  end

  it 'maps the tags of every video, subtitle and attachment stream, with no default that skips them' do
    plan = plan(tracks, video: 2, subtitles: %w[subrip ass], attachments: 1)

    expect(pairs(plan)).to include(['-map_metadata:s:v:0', '0:s:v:0'], ['-map_metadata:s:v:1', '0:s:v:1'],
                                   ['-map_metadata:s:s:0', '0:s:s:0'], ['-map_metadata:s:s:1', '0:s:s:1'],
                                   ['-map_metadata:s:t:0', '0:s:t:0'])
  end

  it 'puts the stamp on the normalised stream and the container, after the explicit mappings' do
    plan = plan(tracks)

    expect(pairs(plan)).to include(['-metadata:s:a:1', a_string_starting_with('NEUTRALISER_PROFILE=')],
                                   ['-metadata', a_string_starting_with('NEUTRALISER_PROFILE=')])
    expect(plan.argv.index('-metadata:s:a:1')).to be > plan.argv.rindex('-map_metadata:s:a:2')
  end

  it 'gives the primary its disposition back, and the stamp follows the primary when a kept original shifts the others' do
    plan = plan(tracks, keep_original: true)

    expect(values(plan, '-map')).to eq(['0:v?', '0:a:0', '[norm]', '0:a:1', '0:a:2', '0:s?', '0:t?'])
    expect(pairs(plan)).to include(['-disposition:a:1', 'default'], ['-disposition:a:2', '0'],
                                   ['-map_metadata:s:a:2', '0:s:a:1'], ['-map_metadata:s:a:3', '0:s:a:2'],
                                   ['-metadata:s:a:2', 'title=English (original, not normalised)'])
    expect(pairs(plan)).to include(['-metadata:s:a:1', a_string_starting_with('NEUTRALISER_PROFILE=')])
  end

  it 'labels the kept original by handler name in MP4, which has no stream title' do
    mp4 = plan(tracks, path: 'film.mp4', output: 'out.mp4', keep_original: true, format_name: 'mov,mp4,m4a,3gp,3g2,mj2')
    mkv = plan(tracks, keep_original: true)

    expect(pairs(mp4)).to include(['-metadata:s:a:2', 'handler_name=English (original, not normalised)'])
    expect(mkv.argv).not_to include(a_string_starting_with('handler_name='))
  end

  describe 'expected output shape' do
    it 'counts the audio streams the output should have, and where the normalised one sits' do
      expect(plan(tracks).layout.size).to eq(3)
      kept = plan(tracks, keep_original: true).layout
      expect([kept.size, kept.normalised.index, kept.kept_original.index]).to eq([4, 1, 2])
    end

    it 'describes the same streams the argv builds' do
      plan = plan(tracks, keep_original: true)
      mapped = values(plan, '-map').select { |m| m.start_with?('0:a:', '[norm]') }

      expect(mapped.length).to eq(plan.layout.size)
    end
  end

  describe 'MP4 stamps' do
    it 'asks for use_metadata_tags only when the file may take mdta keys' do
      with = plan(tracks, path: 'a.mp4', output: 'a.mp4', container: '.mp4')
      without = plan(tracks, path: 'a.mp4', output: 'a.mp4', container: '.mp4', mdta: false)

      expect(pairs(with)).to include(['-movflags', '+use_metadata_tags'])
      expect(without.argv).not_to include('-movflags')
    end

    it 'forces the container with -f when the name lies about it' do
      expect(values(plan(tracks, output: 'out.mkv', container: '.mp4'), '-f')).to eq(['mp4'])
      expect(plan(tracks).argv).not_to include('-f')
    end
  end

  it 'refuses a file with no audio: there is nothing to normalise' do
    expect { plan([]) }.to raise_error(ArgumentError, /no audio/)
  end
end
