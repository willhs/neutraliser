# frozen_string_literal: true

module Neutraliser
  # What `analyze-plex` knows about one title's integrated loudness: a level
  # AND how far from the truth that level can be.
  #
  # A title is either measured in full (exact: the margin is zero, this is
  # the number `process` would see) or sampled from a few short windows. A
  # sample cannot support a +-1 LU verdict. Measured against the full-stream
  # truth on real films (docs/research/plex-sampling-error-2026-10.md), five
  # energy-combined 60s windows were off by up to 6.5 LU, mostly in one
  # direction. So a sampled estimate only gives a verdict when its
  # whole error range falls on one side of the tolerance band; anything else
  # is :unclear, and the title is listed as needing a full measurement
  # instead of being mislabelled.
  class LoudnessEstimate
    # How far the true level can sit from a 5-window estimate, in LU. Measured
    # on 11 Plex films against their full-stream loudness (research note): the
    # estimate read 0 to 6.5 LU QUIETER than the truth (loud scenes carry the
    # energy and a handful of windows miss them) and at most 1.0 LU louder.
    # Each extreme is rounded up by 0.5 LU: they are observed, not guaranteed.
    TRUTH_LOUDER_MARGIN_LU = 7.0
    TRUTH_QUIETER_MARGIN_LU = 1.5
    # Fewer windows than this and a sample is not worth reporting.
    MIN_WINDOWS = 3

    VERDICTS = %i[ok too_loud too_quiet unclear].freeze

    attr_reader :level, :window_count

    # A full-stream measurement: no estimation error.
    def self.exact(level)
      new(level: level, quieter: 0.0, louder: 0.0, window_count: 1)
    end

    # Energy-combines per-window integrated loudness values. LUFS is
    # logarithmic, so windows are averaged as mean-square energy, never as
    # LUFS numbers. Returns nil if fewer than MIN_WINDOWS usable windows.
    def self.sampled(window_levels)
      levels = window_levels.select { |l| l.is_a?(Numeric) && l.finite? }
      return nil if levels.size < MIN_WINDOWS

      mean_energy = levels.sum { |l| 10**(l / 10.0) } / levels.size
      new(level: 10 * Math.log10(mean_energy), quieter: TRUTH_QUIETER_MARGIN_LU,
          louder: TRUTH_LOUDER_MARGIN_LU, window_count: levels.size)
    end

    def initialize(level:, quieter:, louder:, window_count:)
      @level = level
      @quieter = quieter
      @louder = louder
      @window_count = window_count
    end

    def exact?
      @quieter.zero? && @louder.zero?
    end

    # Range the true level can lie in, given what was measured.
    def range
      (level - @quieter)..(level + @louder)
    end

    # :ok / :too_loud / :too_quiet when the whole range agrees, else :unclear.
    def verdict(target, tolerance)
      band = (target - tolerance)..(target + tolerance)

      if band.cover?(range.begin) && band.cover?(range.end)
        :ok
      elsif range.begin > band.end
        :too_loud
      elsif range.end < band.begin
        :too_quiet
      else
        :unclear
      end
    end
  end
end
