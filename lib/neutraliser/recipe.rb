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
    CURRENT = 2
    UNVERSIONED = nil
    UNVERSIONED_LABEL = 'unversioned'.freeze

    # "unversioned" or a whole number: a --redo-recipe value to the recipe it names.
    def self.parse(text)
      return UNVERSIONED if text.to_s.strip.downcase == UNVERSIONED_LABEL
      raise ArgumentError, "Unknown recipe '#{text}': use a number or '#{UNVERSIONED_LABEL}'" unless text.to_s.strip.match?(/\A\d+\z/)

      Integer(text.to_s.strip, 10)
    end

    def self.label(recipe) = recipe.nil? ? UNVERSIONED_LABEL : recipe.to_s

    # A redo of the current recipe would never finish: every file it wrote
    # would qualify again. Older ones and "unversioned" are what a redo is for.
    def self.check_redoable!(recipes)
      stale = recipes.select { |recipe| !recipe.nil? && recipe >= CURRENT }
      return if stale.empty?

      raise ArgumentError, "Recipe #{stale.join(', ')} is the current one (#{CURRENT}) or newer; " \
                           '--redo-recipe is for older recipes and for files with none'
    end
  end
end
