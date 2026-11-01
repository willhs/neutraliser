require 'spec_helper'

RSpec.describe Neutraliser::FinalLevels do
  def stamp(profile: 'livingroom', mode: 'linear', gain: 3.0, loudness: -23.0, lra: 5.0)
    Neutraliser::Stamp.now(profile: profile, mode: mode, gain_db: gain, source_codec: 'aac', source_bitrate: nil,
                           measured_i: loudness, measured_tp: -6.0, measured_lra: lra)
  end

  def left(measured_i: -30.0, lra: 4.0, profile: 'livingroom')
    Neutraliser::LeftRecord.new(reason: 'peak_limited', profile: profile, recipe: 1, message: nil,
                                measured_i: measured_i, measured_tp: -0.5, measured_lra: lra)
  end

  describe '.computed' do
    it 'moves a constant-gain file by its gain and leaves its range alone' do
      expect(described_class.computed(stamp: stamp, left: nil))
        .to have_attributes(integrated: -20.0, lra: 5.0, target: -20.0, basis: :computed)
    end

    it 'puts a dynamic file on target, with the narrower of its range and the profile\'s' do
      expect(described_class.computed(stamp: stamp(profile: 'night', mode: 'dynamic', gain: nil, lra: 14.0), left: nil))
        .to have_attributes(integrated: -16.0, lra: 10.0, target: -16.0)
      expect(described_class.computed(stamp: stamp(profile: 'night', mode: 'dynamic', gain: nil, lra: 3.0), left: nil).lra)
        .to eq(3.0)
      expect(described_class.computed(stamp: stamp(profile: 'night', mode: 'dynamic', gain: nil, loudness: nil, lra: nil), left: nil).lra)
        .to eq(10.0)
    end

    it 'reads a custom profile\'s target from its name' do
      expect(described_class.computed(stamp: stamp(profile: 'custom-18', gain: 5.0, loudness: -23.0), left: nil))
        .to have_attributes(integrated: -18.0, target: -18.0)
    end

    it 'does not guess for a limited file, a --fast constant-gain one, or a profile it does not know' do
      expect(described_class.computed(stamp: stamp(mode: 'limited'), left: nil)).to be_nil
      expect(described_class.computed(stamp: stamp(loudness: nil, lra: nil), left: nil)).to be_nil
      expect(described_class.computed(stamp: stamp(profile: 'mystery'), left: nil)).to be_nil
    end

    it 'takes an untouched file at the levels it was measured on' do
      expect(described_class.computed(stamp: nil, left: left))
        .to have_attributes(integrated: -30.0, lra: 4.0, target: -20.0, basis: :computed)
    end

    it 'has nothing for a file left alone before any measurement, or with no record' do
      expect(described_class.computed(stamp: nil, left: left(measured_i: nil, lra: nil))).to be_nil
      expect(described_class.computed(stamp: nil, left: nil)).to be_nil
    end
  end

  describe '.measured' do
    it 'uses what the file measures, against the given target' do
      measurement = Neutraliser::Measurement.new(input_i: -21.5, input_tp: -3.0, input_lra: 7.0, input_thresh: -31.0,
                                                 target_offset: 0.0)

      expect(described_class.measured(measurement, target: -20.0))
        .to have_attributes(integrated: -21.5, lra: 7.0, target: -20.0, basis: :measured)
    end

    it 'has nothing for a silent file' do
      silent = Neutraliser::Measurement.from_loudnorm_json('input_i' => '-inf', 'input_tp' => '-inf', 'input_lra' => '0.0',
                                                           'input_thresh' => '-70.0', 'target_offset' => '0.0')

      expect(described_class.measured(silent, target: -20.0)).to be_nil
    end
  end
end

RSpec.describe Neutraliser::RemoteFreeRate do
  def levels(integrated, range, basis: :computed)
    Neutraliser::FinalLevels.new(integrated: integrated, lra: range, target: -20.0, basis: basis)
  end

  let(:files) do
    {
      'on.mkv' => levels(-20.5, 6.0),
      'edge.mkv' => levels(-22.0, 12.0),
      'quiet.mkv' => levels(-22.1, 6.0),
      'wide.mkv' => levels(-20.0, 12.1),
      'loud.mkv' => levels(-17.0, 20.0),
      'unknown.mkv' => nil
    }
  end

  subject(:rate) { described_class.new(files) }

  it 'counts a file in when it is within 2 LU of target and at or under the LRA limit, edges included' do
    expect(rate.remote_free?(files['on.mkv'])).to be true
    expect(rate.remote_free?(files['edge.mkv'])).to be true
    expect(rate.remote_free?(files['quiet.mkv'])).to be false
    expect(rate.remote_free?(files['wide.mkv'])).to be false
  end

  it 'takes the rate over the files it could judge, and counts the rest apart' do
    expect(rate.to_h).to include(rate: 0.4, remote_free: 2, judged: 5, not_judged: 1, off_level: 2, wide_range: 2)
  end

  it 'takes its limits from the caller' do
    strict = described_class.new(files, within_lu: 1.0, lra_limit: 6.0)

    expect(strict.to_h).to include(remote_free: 1, within_lu: 1.0, lra_limit: 6.0)
  end

  it 'has no rate when nothing could be judged' do
    none = described_class.new({ 'a.mkv' => nil })

    expect(none.rate).to be_nil
    expect(none.summary).to include('n/a', '1 not judged')
  end

  it 'says whether the levels were computed or measured' do
    expect(rate.summary).to include('computed from records', '40.0%', '2 of 5')
    measured = described_class.new({ 'a.mkv' => levels(-20.0, 5.0, basis: :measured) })
    expect(measured.summary).to include('; measured)')
    mixed = described_class.new({ 'a.mkv' => levels(-20.0, 5.0, basis: :measured), 'b.mkv' => levels(-20.0, 5.0) })
    expect(mixed.summary).to include('1 measured, rest computed')
  end
end
