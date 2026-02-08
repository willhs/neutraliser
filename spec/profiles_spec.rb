require 'spec_helper'

RSpec.describe Neutraliser::Profiles do
  describe '.get_profile' do
    it 'returns built-in profile by name' do
      profile = described_class.get_profile('livingroom')

      expect(profile).to include(name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0)
    end

    it 'returns exact custom profile for numeric target' do
      profile = described_class.get_profile(-22.9)

      expect(profile).to include(name: 'custom', lufs: -22.9, tp: -1.5, lra: 12.0)
    end

    it 'raises for unknown profile name' do
      expect { described_class.get_profile('unknown') }.to raise_error(ArgumentError, /Unknown profile/)
    end
  end

  describe '.custom_profile' do
    it 'builds a custom profile hash' do
      profile = described_class.custom_profile(-18.0, name: 'my-profile', tp: -2.0, lra: 9.0)

      expect(profile).to eq(name: 'my-profile', lufs: -18.0, tp: -2.0, lra: 9.0)
    end
  end

  describe '.list_profiles' do
    it 'lists built-in profiles' do
      expect(described_class.list_profiles).to contain_exactly('reference', 'livingroom', 'night')
    end
  end

  describe '.default_profile' do
    it 'uses livingroom as default profile' do
      expect(described_class.default_profile[:name]).to eq('livingroom')
    end
  end
end
