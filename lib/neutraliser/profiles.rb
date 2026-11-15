module Neutraliser
  class Profiles
    # Basic profile definitions for Phase 1
    REFERENCE = { name: 'reference', lufs: -23.0, tp: -1.5, lra: 50.0, dynamic: false }.freeze
    LIVING_ROOM = { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0, dynamic: false }.freeze
    NIGHT_MODE = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0, dynamic: true }.freeze

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
        raise ArgumentError, 'Profile must be a string name or numeric LUFS value'
      end
    end

    # The profile a stamp's name stands for, or nil when it names none we know.
    # Custom names carry their target (`custom-18`), so they can be rebuilt.
    def self.find(name)
      return PROFILES[name] if PROFILES.key?(name)

      match = name.to_s.match(/\Acustom([+-]?\d+(?:\.\d+)?)\z/)
      return custom_profile(match[1].to_f) if match

      match = name.to_s.match(/\Adialogue([+-]?\d+(?:\.\d+)?)\z/)
      match && dialogue_profile(match[1].to_f)
    end

    # A dialogue-anchored aim (Ladder, --anchor dialogue): each file's dialogue at `dialogue_target`
    # LUFS. :lufs is the programme level a file with no dialogue estimate is levelled to; Ladder.aim
    # works out every other file's. The name carries the target, as custom ones do, and says it is
    # dialogue: a file levelled so its dialogue sits at -27 isn't done for a -27 programme.
    def self.dialogue_profile(dialogue_target, tp: -1.5, lra: 12.0)
      { name: format('dialogue%+g', dialogue_target), lufs: dialogue_target.to_f + Ladder::NO_DIALOGUE_OFFSET_LU, tp: tp,
        lra: lra, dynamic: false, anchor: :dialogue, dialogue_target: dialogue_target.to_f }
    end

    # `dynamic: true` marks a compression profile: it implies allow-dynamic,
    # so loudnorm may squash dynamic range without the --allow-dynamic flag.
    # The default name carries the target because stamps, sidecars and caches
    # match on the name: a file done at -18 isn't done at -24.
    def self.custom_profile(target_lufs, name: nil, tp: -1.5, lra: 12.0, dynamic: false)
      { name: name || format('custom%+g', target_lufs), lufs: target_lufs.to_f, tp: tp, lra: lra, dynamic: dynamic }
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
        'Reference/Home Theater profile for best fidelity with AVR systems'
      when 'livingroom'
        'Living-room/Soundbar profile for general TV viewing (recommended)'
      when 'night'
        'Night mode compression profile (implies dynamic): reduced dynamic range for quiet listening'
      else
        return "Dialogue at #{profile[:dialogue_target]} LUFS (--anchor dialogue)" if profile[:anchor] == :dialogue

        "Custom profile with #{profile[:lufs]} LUFS target"
      end
    end
  end
end
