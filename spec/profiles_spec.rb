require 'spec_helper'

RSpec.describe Neutraliser::Profiles do
  describe '.get_profile' do
    context 'with profile name' do
      it 'returns REFERENCE profile for "reference"' do
        result = described_class.get_profile('reference')
        expect(result[:name]).to eq('reference')
        expect(result[:lufs]).to eq(-23.0)
        expect(result[:tp]).to eq(-1.5)
        expect(result[:lra]).to eq(50.0)
      end

      it 'returns LIVING_ROOM profile for "livingroom"' do
        result = described_class.get_profile('livingroom')
        expect(result[:name]).to eq('livingroom')
        expect(result[:lufs]).to eq(-20.0)
        expect(result[:tp]).to eq(-1.5)
        expect(result[:lra]).to eq(12.0)
      end

      it 'returns NIGHT_MODE profile for "night"' do
        result = described_class.get_profile('night')
        expect(result[:name]).to eq('night')
        expect(result[:lufs]).to eq(-16.0)
        expect(result[:tp]).to eq(-1.5)
        expect(result[:lra]).to eq(10.0)
      end

      it 'raises ArgumentError for unknown profile name' do
        expect {
          described_class.get_profile('unknown')
        }.to raise_error(ArgumentError, /Unknown profile: unknown/)
      end
    end

    context 'with numeric LUFS value' do
      it 'finds closest profile for -23.1 (close to REFERENCE)' do
        result = described_class.get_profile(-23.1)
        expect(result[:name]).to eq('reference_closest')
        expect(result[:lufs]).to eq(-23.0)
      end

      it 'finds closest profile for -19.8 (close to LIVING_ROOM)' do
        result = described_class.get_profile(-19.8)
        expect(result[:name]).to eq('livingroom_closest')
        expect(result[:lufs]).to eq(-20.0)
      end

      it 'finds closest profile for -15.5 (close to NIGHT_MODE)' do
        result = described_class.get_profile(-15.5)
        expect(result[:name]).to eq('night_closest')
        expect(result[:lufs]).to eq(-16.0)
      end

      it 'returns custom profile for values far from standards' do
        result = described_class.get_profile(-12.0)
        expect(result[:lufs]).to eq(-12.0)
        expect(result[:tp]).to eq(-1.5)
        expect(result[:lra]).to eq(12.0)
        expect(result[:name]).to eq('custom')
      end

      it 'handles edge case between profiles' do
        # Exactly between LIVING_ROOM (-20.0) and NIGHT_MODE (-16.0)
        result = described_class.get_profile(-18.0)
        # Should pick the closer one (LIVING_ROOM is 2.0 away, NIGHT_MODE is 2.0 away)
        # Implementation should pick one consistently
        expect(result[:lufs]).to be_within(0.1).of(-18.0).or eq(-20.0).or eq(-16.0)
      end
    end

    context 'with invalid input' do
      it 'raises appropriate error for nil' do
        expect {
          described_class.get_profile(nil)
        }.to raise_error(ArgumentError)
      end
    end
  end

  describe '.list_profiles' do
    it 'returns all available profile names' do
      result = described_class.list_profiles
      expect(result).to contain_exactly('reference', 'livingroom', 'night')
    end
  end

  describe '.find_closest_profile (private)' do
    # Test the private method indirectly through get_profile
    it 'correctly identifies closest profile within threshold' do
      # Test values that should match each profile
      expect(described_class.get_profile(-22.8)[:name]).to eq('reference_closest')
      expect(described_class.get_profile(-20.2)[:name]).to eq('livingroom_closest')
      expect(described_class.get_profile(-16.3)[:name]).to eq('night_closest')
    end

    it 'returns custom profile for values too far from any profile' do
      # Test a value that's far from any standard profile
      result = described_class.get_profile(-5.0)
      expect(result[:name]).to eq('custom')
      expect(result[:lufs]).to eq(-5.0)
    end
  end

  describe 'profile constants' do
    it 'defines REFERENCE profile correctly' do
      expect(Neutraliser::Profiles::REFERENCE[:name]).to eq('reference')
      expect(Neutraliser::Profiles::REFERENCE[:lufs]).to eq(-23.0)
      expect(Neutraliser::Profiles::REFERENCE[:tp]).to eq(-1.5)
      expect(Neutraliser::Profiles::REFERENCE[:lra]).to eq(50.0)
    end

    it 'defines LIVING_ROOM profile correctly' do
      expect(Neutraliser::Profiles::LIVING_ROOM[:name]).to eq('livingroom')
      expect(Neutraliser::Profiles::LIVING_ROOM[:lufs]).to eq(-20.0)
      expect(Neutraliser::Profiles::LIVING_ROOM[:tp]).to eq(-1.5)
      expect(Neutraliser::Profiles::LIVING_ROOM[:lra]).to eq(12.0)
    end

    it 'defines NIGHT_MODE profile correctly' do
      expect(Neutraliser::Profiles::NIGHT_MODE[:name]).to eq('night')
      expect(Neutraliser::Profiles::NIGHT_MODE[:lufs]).to eq(-16.0)
      expect(Neutraliser::Profiles::NIGHT_MODE[:tp]).to eq(-1.5)
      expect(Neutraliser::Profiles::NIGHT_MODE[:lra]).to eq(10.0)
    end

    it 'keeps profiles frozen for immutability' do
      expect(Neutraliser::Profiles::REFERENCE).to be_frozen
      expect(Neutraliser::Profiles::LIVING_ROOM).to be_frozen
      expect(Neutraliser::Profiles::NIGHT_MODE).to be_frozen
      expect(Neutraliser::Profiles::PROFILES).to be_frozen
    end
  end

  describe 'profile validation' do
    it 'ensures all profiles have required keys' do
      Neutraliser::Profiles::PROFILES.each do |name, profile|
        expect(profile).to have_key(:name)
        expect(profile).to have_key(:lufs)
        expect(profile).to have_key(:tp)
        expect(profile).to have_key(:lra)
        expect(profile[:name]).to eq(name)
      end
    end

    it 'ensures LUFS values are in reasonable broadcast range' do
      Neutraliser::Profiles::PROFILES.each do |_, profile|
        expect(profile[:lufs]).to be_between(-30, -10)
      end
    end

    it 'ensures true peak values are reasonable' do
      Neutraliser::Profiles::PROFILES.each do |_, profile|
        expect(profile[:tp]).to be_between(-3, 0)
      end
    end

    it 'ensures LRA values are positive or infinite' do
      Neutraliser::Profiles::PROFILES.each do |_, profile|
        expect(profile[:lra]).to be > 0
      end
    end
  end
end