require 'spec_helper'
require 'tmpdir'
require_relative 'support/lra_fixture'

# Research 0007 findings 6 and 8: seven channels with no layout name (ffmpeg's own AAC 6.1) failed every
# measure, because the ebur128 branch of the split read cannot map them.
RSpec.describe 'A 7-channel track with an unnamed layout' do
  describe Neutraliser::Measurement, '.side_channels' do
    it 'asks for 6.1 when seven channels have no layout name' do
      expect(described_class.side_channels({ channels: 7, channel_layout: 'unknown' })).to eq(channels: 7, layout: '6.1')
      expect(described_class.side_channels({ channels: 7, channel_layout: nil })).to eq(channels: 7, layout: '6.1')
    end

    it 'leaves a named seven-channel layout, 7.1 and 5.1 alone' do
      expect(described_class.side_channels({ channels: 7, channel_layout: '6.1' })).to eq(channels: 7)
      expect(described_class.side_channels({ channels: 8, channel_layout: '7.1' })).to eq(channels: 8)
      expect(described_class.side_channels({ channels: 6, channel_layout: 'unknown' })).to eq({})
    end
  end

  it 'puts the layout into the split read after any pre-filter' do
    args = Neutraliser::FFmpegWrapper.send(:loudness_graph_args, 0, 'volume=1', 'loudnorm', 7, '6.1')
    expect(args[1]).to start_with('[0:a:0]volume=1,aformat=channel_layouts=6.1,asplit[a][b]')
  end

  it 'measures a real unnamed 7-channel AAC', :real_ffmpeg do
    skip 'ffmpeg not available' unless system('which ffmpeg ffprobe > /dev/null 2>&1')
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'six_one.mkv')
      LraFixture.run!('ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'anoisesrc=color=pink:duration=5:sample_rate=48000:amplitude=0.1:seed=1',
                      '-filter_complex', '[0:a]aformat=channel_layouts=mono,pan=6.1|FL=c0|FR=c0|FC=c0|LFE=c0|BC=c0|SL=c0|SR=c0[a]',
                      '-map', '[a]', '-c:a', 'aac', '-b:a', '384k', path)
      track = Neutraliser::Source.new(path).primary_track
      expect(track[:channels]).to eq(7)
      measured = Neutraliser::FFmpegWrapper.measure_loudness(path, audio_index: track[:index], **Neutraliser::Measurement.side_channels(track))
      expect(measured.input_i).to be_between(-60, 0)
    end
  end
end
