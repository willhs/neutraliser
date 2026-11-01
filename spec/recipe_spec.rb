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
      expect { described_class.check_redoable!([3]) }.to raise_error(ArgumentError, /current one \(3\)/)
      expect { described_class.check_redoable!([4]) }.to raise_error(ArgumentError)
    end
  end
end
