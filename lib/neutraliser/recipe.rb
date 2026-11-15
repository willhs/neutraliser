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
    # non-monotonic (check_redoable! reads "newer" as "higher").
    CONSTANT_GAIN = 2
    # 3: the levelling ladder (Ladder, --ladder): the least of gain, limiter and compression that
    # works for each file, aimed at the programme or the dialogue.
    LADDER = 3
    # What a run writes when not told otherwise. Switching the default to the ladder is this one
    # line (CURRENT = LADDER): --ladder defaults to on when it is.
    CURRENT = CONSTANT_GAIN
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
