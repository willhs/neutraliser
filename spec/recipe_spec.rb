require 'spec_helper'

RSpec.describe Neutraliser::Recipe do
  it 'parses a number or the word unversioned' do
    expect(described_class.parse('2')).to eq(2)
    expect(described_class.parse(' unversioned ')).to be_nil
    expect(described_class.parse('Unversioned')).to be_nil
  end

  it 'rejects anything else' do
    expect { described_class.parse('latest') }.to raise_error(ArgumentError, /Unknown recipe 'latest'/)
    expect { described_class.parse('-1') }.to raise_error(ArgumentError)
    expect { described_class.parse('') }.to raise_error(ArgumentError)
  end

  it 'labels a recipe for display' do
    expect(described_class.label(3)).to eq('3')
    expect(described_class.label(nil)).to eq('unversioned')
  end

  describe '.check_redoable!' do
    before { stub_const('Neutraliser::Recipe::CURRENT', 3) }

    it 'accepts older recipes and unversioned' do
      expect { described_class.check_redoable!([1, 2, nil]) }.not_to raise_error
    end

    it 'refuses the current recipe or a newer one, which no run could finish' do
      expect { described_class.check_redoable!([3]) }.to raise_error(ArgumentError, /this run writes \(3\)/)
      expect { described_class.check_redoable!([4]) }.to raise_error(ArgumentError)
    end

    it 'judges against the recipe the run writes: a ladder run may redo recipe 2' do
      expect { described_class.check_redoable!([2], writing: Neutraliser::Recipe::LADDER) }.not_to raise_error
      expect { described_class.check_redoable!([3], writing: Neutraliser::Recipe::LADDER) }.to raise_error(ArgumentError)
    end
  end
  describe '.six_channel_meter?' do
    let(:before_fix) { Neutraliser::Recipe::SIDE_CHANNELS_METERED_FROM - 60 }
    let(:after_fix) { Neutraliser::Recipe::SIDE_CHANNELS_METERED_FROM + 60 }

    it 'is true for a 7.1 judgement made before the side channels were metered, or of unknown date' do
      expect(described_class.six_channel_meter?(channels: 8, judged_at: before_fix)).to be true
      expect(described_class.six_channel_meter?(channels: 8, judged_at: nil)).to be true
    end

    it 'is false for a 7.1 judgement made since' do
      expect(described_class.six_channel_meter?(channels: 8, judged_at: after_fix)).to be false
    end

    it 'is false for six channels or fewer whatever the date: the meter never changed for them' do
      expect(described_class.six_channel_meter?(channels: 6, judged_at: before_fix)).to be false
      expect(described_class.six_channel_meter?(channels: 2, judged_at: nil)).to be false
    end
  end
end
