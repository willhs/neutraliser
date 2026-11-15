module Neutraliser
  # Which version of the leveling method wrote a file's audio. A profile name
  # says where to aim ("livingroom"); the recipe says how it gets there
  # (constant gain, peak-capped ...). When the method changes, the same profile
  # name would otherwise cover files made two different ways, and nothing could
  # tell them apart or find the old ones.
  #
  # CURRENT is bumped only when a change makes new output differ on purpose.
  # A stamp or sidecar entry with no recipe predates versioning (nil): still
  # valid, and identifiable as UNVERSIONED. Which recipe a file carries never
  # makes a run re-encode it: only an explicit --redo-recipe does (see
  # SkipDecider), because re-leveling a library is a decision, not a side
  # effect of upgrading.
  module Recipe
    # 2: AC-3 / E-AC-3 tracks are decoded with the stream's DRC off and keep their dialnorm
    # (DolbyStream), so their measured levels, and the gain from them, differ from recipe 1.
    # Constant gain, peak-capped (plus whatever --limit-db / --lra-target asked for).
    # Not bumped for 7.1 (research 0003 finding 14): tracks with more than six channels are now measured
    # with ebur128 alongside loudnorm, which only counts six, so they land on target instead of up to
    # ~1.8 LU over. That corrects a measurement defect in the same method rather than adding a new one,
    # nothing here has been released yet, and a number above LADDER would make the recipes
    # non-monotonic (check_redoable! reads "newer" as "higher"). Files levelled before that are found by
    # SIDE_CHANNELS_METERED_FROM, not by recipe.
    CONSTANT_GAIN = 2
    # 3: the levelling ladder (Ladder, --ladder): the least of gain, limiter and compression that
    # works for each file, aimed at the programme or the dialogue.
    LADDER = 3
    # What a run writes when not told otherwise. Switching the default to the ladder is this one
    # line (CURRENT = LADDER): --ladder defaults to on when it is.
    CURRENT = CONSTANT_GAIN
    # From this moment (UTC; just after the last 7.1 measurement change, 172a5fb) a track above six channels
    # is metered over all of them. Neither recipe nor cache version can mark that: the recipe stayed at 2 on
    # purpose (see CONSTANT_GAIN), and a 7.1 file's stamp is otherwise the same as a 5.1 one's. What tells a
    # file levelled by the six-channel meter apart is its channel count and when it was judged, so
    # `process --redo-side-channels` selects on those (SkipDecider).
    SIDE_CHANNELS_METERED_FROM = Time.utc(2026, 11, 15, 12, 40, 0)

    # True when a judgement of a track with this many channels, made at judged_at (a Time, or nil when no
    # date is known), was made with loudnorm's six-channel meter. An unknown date counts as old: reading a
    # file again costs a measurement, trusting a wrong figure costs a mis-levelled file.
    def self.six_channel_meter?(channels:, judged_at:)
      channels.to_i > Measurement::LOUDNORM_CHANNELS && (judged_at.nil? || judged_at < SIDE_CHANNELS_METERED_FROM)
    end

    UNVERSIONED = nil
    UNVERSIONED_LABEL = 'unversioned'.freeze

    # "unversioned" or a whole number: a --redo-recipe value to the recipe it names.
    def self.parse(text)
      return UNVERSIONED if text.to_s.strip.downcase == UNVERSIONED_LABEL
      raise ArgumentError, "Unknown recipe '#{text}': use a number or '#{UNVERSIONED_LABEL}'" unless text.to_s.strip.match?(/\A\d+\z/)

      Integer(text.to_s.strip, 10)
    end

    # The recipe a run writes.
    def self.for(ladder:) = ladder ? LADDER : CONSTANT_GAIN

    def self.label(recipe) = recipe.nil? ? UNVERSIONED_LABEL : recipe.to_s

    # A redo of the recipe this run writes would never finish: every file it wrote
    # would qualify again. Older ones and "unversioned" are what a redo is for.
    def self.check_redoable!(recipes, writing: CURRENT)
      stale = recipes.select { |recipe| !recipe.nil? && recipe >= writing }
      return if stale.empty?

      raise ArgumentError, "Recipe #{stale.join(', ')} is the one this run writes (#{writing}) or newer; " \
                           '--redo-recipe is for older recipes and for files with none'
    end
  end
end
