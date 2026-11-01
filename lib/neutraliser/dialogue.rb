module Neutraliser
  # Read-only dialogue figures for one file, beside the programme loudness the rest of the tool judges by.
  # Nothing here changes audio: it is how a library looks when anchored on dialogue instead of the whole
  # mix (research: docs/research/0002-streaming-loudness-and-dialogue/research.md, section 5c). Every
  # figure says which method produced it, because the methods differ by LU in size and a number without
  # its method cannot be compared or trusted.

  # The target a dialogue-anchored library is judged against: dialogue at `target` LUFS, the programme no
  # more than `ldr_limit` LU above it (EBU R 128 s4's loudness above dialogue).
  DialogueAnchor = Data.define(:target, :ldr_limit)
  DialogueAnchor::DEFAULT = DialogueAnchor.new(target: -27.0, ldr_limit: 5.0)

  # How loud a file's dialogue is, or why that can't be said. Invariant: `level` (LUFS) is set exactly when
  # `method` is, and `reason` exactly when it isn't.
  #
  # method says how the level was got (METHODS); confidence is how far to trust it. speech_share is the
  # fraction of the file that is speech, which only a voice detector can say: nil for a method without one.
  DialogueEstimate = Data.define(:level, :method, :confidence, :speech_share, :reason) do
    def self.centre_channel(level)
      new(level: level, method: :centre_channel, confidence: :medium, speech_share: nil, reason: nil)
    end

    def self.unavailable(reason)
      new(level: nil, method: nil, confidence: nil, speech_share: nil, reason: reason)
    end

    def available? = !level.nil?
    def method_text = self.class::METHODS.fetch(method)
  end

  # method => words for a person, with the error the research measured on synthetic 5.1 mixes that had a
  # known dialogue level (real films are untested).
  DialogueEstimate::METHODS = {
    centre_channel: 'centre channel through the EBU R 128 gate (reads high when effects or music share that channel: ' \
                    '-0.7 to +3.4 LU on film-shaped test mixes, +18.7 LU on the worst one tried)'
  }.freeze

  # One file's dialogue figures: the programme loudness (LUFS), the dialogue estimate, and the dialnorm the
  # file carries (dB, -31 to -1; nil when it has none: not Dolby, or unreadable). dialnorm is the track's own
  # statement of its dialogue level, an independent figure to check the estimate against on untouched files.
  Dialogue = Data.define(:programme, :estimate, :dialnorm) do
    # Programme minus dialogue, in LU: how far the mix runs above the speech.
    def ldr = estimate.available? ? programme - estimate.level : nil
    def judged? = estimate.available?
  end

  # The share of files whose dialogue sits on the anchor: within `within_lu` of its target, and the programme
  # no more than the anchor's `ldr_limit` above it. The dialogue-anchored counterpart of RemoteFreeRate. A
  # file with no estimate is counted apart, never guessed at.
  class DialogueRate
    attr_reader :anchor, :within_lu

    # dialogue_per_file: file => Dialogue, or nil where the file couldn't be measured at all.
    def initialize(dialogue_per_file, anchor: DialogueAnchor::DEFAULT, within_lu: RemoteFreeRate::WITHIN_LU)
      @dialogue = dialogue_per_file
      @anchor = anchor
      @within_lu = within_lu.to_f
    end

    def level_ok?(dialogue) = (dialogue.estimate.level - anchor.target).abs <= within_lu
    def ldr_ok?(dialogue) = dialogue.ldr <= anchor.ldr_limit
    def remote_free?(dialogue) = !!dialogue&.judged? && level_ok?(dialogue) && ldr_ok?(dialogue)

    # true / false for a judged file, nil for one with no estimate (or none at all): neither pass nor fail.
    def verdict(dialogue) = dialogue&.judged? ? remote_free?(dialogue) : nil

    def judged = @dialogue.values.compact.select(&:judged?)
    def not_judged = @dialogue.size - judged.size
    def remote_free = judged.count { |dialogue| remote_free?(dialogue) }
    def off_level = judged.count { |dialogue| !level_ok?(dialogue) }
    def over_ldr = judged.count { |dialogue| !ldr_ok?(dialogue) }

    # Fraction 0.0..1.0, or nil when no file could be judged.
    def rate = judged.empty? ? nil : remote_free.fdiv(judged.size)

    def methods_used = judged.map { |dialogue| dialogue.estimate.method }.tally

    def to_h
      { rate: rate&.round(4), remote_free: remote_free, judged: judged.size, not_judged: not_judged,
        off_level: off_level, over_ldr: over_ldr, methods: methods_used.transform_keys(&:to_s),
        dialogue_target: anchor.target, ldr_limit: anchor.ldr_limit, within_lu: within_lu }
    end

    # Lines for a person: the rate, and the figures it rests on. Empty when nothing was measured.
    def summary_lines
      return [] if @dialogue.empty?

      [rate_line, *ldr_line, *dialnorm_line]
    end

    private

    def rate_line
      return "Dialogue-anchored remote-free rate: n/a (no file's dialogue could be estimated#{not_judged_note})" unless rate

      "Dialogue-anchored remote-free rate: #{(rate * 100).round(1)}% (#{remote_free} of #{judged.size} judged files with " \
        "dialogue within #{within_lu} LU of #{anchor.target} LUFS and programme at most #{anchor.ldr_limit} LU above it; " \
        "method: #{methods_text}#{not_judged_note})"
    end

    def ldr_line
      return [] if judged.empty?

      ldrs = judged.map(&:ldr).sort
      ["Loudness above dialogue: median #{format('%.1f', ldrs[ldrs.size / 2])} LU, #{over_ldr} of #{judged.size} over #{anchor.ldr_limit} LU"]
    end

    def dialnorm_line
      dialnorms = @dialogue.values.compact.filter_map(&:dialnorm).tally.sort.to_h
      return [] if dialnorms.empty?

      ["Dialnorm in the files (dB): #{dialnorms.map { |db, n| "#{db}=#{n}" }.join(', ')}"]
    end

    def methods_text = methods_used.keys.map { |method| DialogueEstimate::METHODS.fetch(method) }.join('; ')

    def not_judged_note
      return '' if not_judged.zero?

      "; #{not_judged} not judged: #{unavailable_reasons.map { |reason, n| "#{reason} (#{n})" }.join(', ')}"
    end

    def unavailable_reasons
      @dialogue.values.map { |dialogue| dialogue ? dialogue.estimate.reason : 'could not be measured' }.compact.tally
    end
  end
end
