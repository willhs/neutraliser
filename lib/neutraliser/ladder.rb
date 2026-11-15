module Neutraliser
  # The levelling ladder (--ladder, recipe 3): do the least that works for each file.
  #
  #   1 gain      constant gain, when the file reaches its target within the peak ceiling
  #   2 limiter   plus a peak limiter, when peaks block the gain (up to LIMIT_DB, GainPlan)
  #   3 compress  plus compression, when the loudness range is over LRA_LIMIT (Compression)
  #   + convert   a lossless or object-audio track re-encoded to another codec (or flattened); only
  #               where --allow-codec-change / --allow-object-audio-loss let it, so other people's
  #               libraries keep the cautious defaults
  #
  # Nothing here levels audio: the rungs are GainPlan and Compression, which already run in this order
  # (Processor#process_file_two_pass). The ladder is their defaults, switched on together, plus where a
  # file is aimed: its whole programme at the profile's level, or its dialogue at a dialogue target.
  module Ladder
    # Rung 2's reach: how far a limiter may pull peaks down so the gain can reach target (vision: 6-8 dB).
    LIMIT_DB = 6.0
    # Rung 3's trigger: compress when the loudness range is over this (vision: about 12-14 LU).
    LRA_LIMIT = 13.0
    # With no dialogue estimate (stereo, mono, a silent centre), a dialogue-anchored file aims its
    # programme this far above the dialogue target: Netflix's -24 programme for -27 dialogue (research 0002).
    NO_DIALOGUE_OFFSET_LU = 3.0
    ANCHORS = %w[programme dialogue].freeze

    module_function

    # Where one file is levelled to: a profile hash with the profile's name and this file's programme
    # target as :lufs, so GainPlan, Compression and the tolerance checks work on it unchanged.
    #
    # A programme anchor aims every file at the profile. A dialogue anchor aims the programme at the
    # dialogue target plus the file's own loudness above dialogue, so the dialogue lands on target;
    # :dialogue_i says which estimate that came from (nil: none, so the profile's fallback level).
    # Loudness above dialogue is floored at 0: a centre channel reading louder than the whole mix is a
    # bad estimate, not a mix whose dialogue is over everything else.
    def aim(profile, programme_i, estimate)
      return profile unless profile[:anchor] == :dialogue
      return profile.merge(dialogue_i: nil) unless estimate&.available?

      above = [programme_i - estimate.level, 0.0].max
      profile.merge(lufs: (profile[:dialogue_target] + above).round(2), dialogue_i: estimate.level.round(2))
    end

    # Which rung a stamped file took, read back from its stamp and its primary track as it is now.
    # Derived rather than stamped, so files made before the ladder get one too. nil for a file with no stamp.
    Rung = Data.define(:mode, :convert) do
      def self.of(stamp, track)
        return nil unless stamp

        new(mode: stamp.mode.to_s, convert: converted?(stamp, track))
      end

      # The codec changed (DTS to FLAC, TrueHD to E-AC-3), or object audio was flattened (the codec can
      # stay E-AC-3 while the Atmos goes).
      def self.converted?(stamp, track)
        codec_now = track && track[:codec].to_s.downcase
        changed = !stamp.source_codec.to_s.empty? && !codec_now.to_s.empty? && stamp.source_codec.to_s.downcase != codec_now
        changed || ObjectAudio.object_profile?(stamp.source_profile)
      end

      def step = Ladder::Rung::STEPS.fetch(mode, mode.empty? ? 'unknown' : mode)
      def label = convert ? "#{step}+convert" : step
    end

    # Modes off the ladder (dynamic: loudnorm chose; unknown) keep their own word.
    Rung::STEPS = { Mode::LINEAR.to_s => '1-gain', Mode::LIMITED.to_s => '2-limiter',
                    Mode::COMPRESSED.to_s => '3-compress' }.freeze
  end
end
