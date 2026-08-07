module Neutraliser
  class Profiles
    # Basic profile definitions for Phase 1
    REFERENCE = { name: 'reference', lufs: -23.0, tp: -1.5, lra: 50.0 }.freeze
    LIVING_ROOM = { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 }.freeze
    NIGHT_MODE = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }.freeze

    PROFILES = {
      'reference' => REFERENCE,
      'livingroom' => LIVING_ROOM,
      'night' => NIGHT_MODE
    }.freeze

    def self.get_profile(name_or_lufs)
      case name_or_lufs
      when String
        profile = PROFILES[name_or_lufs]
        raise ArgumentError, "Unknown profile: #{name_or_lufs}. Available: #{PROFILES.keys.join(', ')}" unless profile
        profile
      when Numeric
        custom_profile(name_or_lufs.to_f)
      else
        raise ArgumentError, "Profile must be a string name or numeric LUFS value"
      end
    end

    def self.custom_profile(target_lufs, name: 'custom', tp: -1.5, lra: 12.0)
      { name: name, lufs: target_lufs.to_f, tp: tp, lra: lra }
    end

    def self.list_profiles
      PROFILES.keys
    end

    def self.default_profile
      LIVING_ROOM
    end

    def self.describe_profile(profile)
      case profile[:name]
      when 'reference'
        "Reference/Home Theater profile for best fidelity with AVR systems"
      when 'livingroom'
        "Living-room/Soundbar profile for general TV viewing (recommended)"
      when 'night'
        "Night mode profile with reduced dynamic range for quiet listening"
      else
        "Custom profile with #{profile[:lufs]} LUFS target"
      end
    end
  end
end
