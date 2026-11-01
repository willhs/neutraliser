require 'spec_helper'

RSpec.describe Neutraliser::Stamp do
  let(:stamp) do
    described_class.now(profile: 'livingroom', mode: 'linear', gain_db: 3.456, source_codec: 'eac3',
                        source_bitrate: 640_000, measured_i: -23.1, measured_tp: -6.0, measured_lra: 7.25)
  end

  it 'round-trips through its tags' do
    restored = described_class.from_tags(stamp.to_tags)

    expect(restored).to have_attributes(profile: 'livingroom', mode: 'linear', gain_db: 3.46, source_codec: 'eac3',
                                        source_bitrate: 640_000, measured_i: -23.1, version: Neutraliser::VERSION,
                                        date: stamp.date)
  end

  it 'carries the recipe, and reads a stamp from before recipes as unversioned' do
    expect(stamp.recipe).to eq(Neutraliser::Recipe::CURRENT)
    expect(stamp.to_tags).to include('NEUTRALISER_RECIPE' => Neutraliser::Recipe::CURRENT.to_s)
    expect(described_class.from_tags(stamp.to_tags)).to have_attributes(recipe: Neutraliser::Recipe::CURRENT)

    legacy = stamp.to_tags.except('NEUTRALISER_RECIPE')
    expect(described_class.from_tags(legacy)).to have_attributes(profile: 'livingroom', recipe: nil)
    expect(described_class.from_tags(stamp.to_tags.merge('NEUTRALISER_RECIPE' => ''))).to have_attributes(recipe: nil)
    expect(stamp.with(recipe: nil).recipe).to be_nil
  end

  it 'writes every field, empty when unknown, so stale tags from an earlier run are deleted' do
    tags = described_class.now(profile: 'night', mode: 'dynamic', gain_db: nil, source_codec: 'aac',
                               source_bitrate: nil, measured_i: nil, measured_tp: nil, measured_lra: nil).to_tags

    expect(tags.keys).to all(start_with('NEUTRALISER_'))
    expect(tags.size).to eq(described_class.members.size)
    expect(tags).to include('NEUTRALISER_GAIN_DB' => '', 'NEUTRALISER_MODE' => 'dynamic')
  end

  it 'reads tags whatever their case (containers differ)' do
    tags = stamp.to_tags.transform_keys(&:downcase)

    expect(described_class.from_tags(tags)).to have_attributes(profile: 'livingroom')
  end

  it 'is nil when there is no neutraliser profile tag' do
    expect(described_class.from_tags('language' => 'eng')).to be_nil
    expect(described_class.from_tags(nil)).to be_nil
    expect(described_class.from_tags('NEUTRALISER_PROFILE' => '')).to be_nil
  end

  describe 'compression fields' do
    let(:compressed) do
      described_class.now(profile: 'livingroom', mode: 'compressed', gain_db: 6.7, source_codec: 'ac3', source_bitrate: 448_000,
                          measured_i: -21.8, measured_tp: -8.0, measured_lra: 16.4,
                          compression: 'gentle+limiter', centre_boost_db: 4.0, lra_after: 10.7)
    end

    it 'round-trips the rung, centre boost and LRA after' do
      restored = described_class.from_tags(compressed.to_tags)

      expect(restored).to be_compressed
      expect(restored).to have_attributes(compression: 'gentle+limiter', centre_boost_db: 4.0, lra_after: 10.7, measured_lra: 16.4)
    end

    it 'leaves them empty on every other stamp, so a re-run clears stale values' do
      tags = stamp.to_tags

      expect(tags).to include('NEUTRALISER_COMPRESSION' => '', 'NEUTRALISER_CENTRE_BOOST_DB' => '', 'NEUTRALISER_LRA_AFTER' => '')
      expect(described_class.from_tags(tags)).to have_attributes(compression: nil, lra_after: nil)
    end
  end
end
