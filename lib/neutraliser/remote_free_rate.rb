module Neutraliser
  # Where one file's audio ends up: integrated loudness (LUFS) and loudness
  # range (LU), judged against the target it was aimed at (LUFS).
  # basis says how the numbers were got: :computed from what the stamp or
  # left record says happened (cheap, an estimate), or :measured by reading the
  # file as it is now.
  FinalLevels = Data.define(:integrated, :lra, :target, :basis) do
    # Computed from the record alone. nil when the record cannot say: no
    # record, or one without the measurements it needs (a --fast stamp for a
    # constant-gain file, say).
    def self.computed(stamp:, left:)
      return from_stamp(stamp) if stamp

      from_left(left) if left&.measured?
    end

    def self.measured(measurement, target:)
      return nil if measurement.silent?

      new(integrated: measurement.input_i, lra: measurement.input_lra, target: target, basis: :measured)
    end

    # Constant gain moves loudness one-for-one and leaves the range alone, so only a
    # linear stamp can be computed. The others wait for a measurement, because the
    # record can't say where they landed: a limiter takes loudness off the gain the
    # stamp records (a test clip aimed at -20 LUFS landed at -26), compression moves
    # the level between the measured_i and the gain_db it records, and loudnorm's
    # dynamic mode doesn't hold the profile's target or range (measured: -26 LUFS and
    # LRA 15.4 on a clip aimed at -20 and 12).
    def self.from_stamp(stamp)
      profile = Profiles.find(stamp.profile)
      return nil unless profile && stamp.linear? && stamp.measured_i && stamp.measured_lra

      new(integrated: stamp.measured_i + stamp.gain_db.to_f, lra: stamp.measured_lra, target: profile[:lufs],
          basis: :computed)
    end

    # Left alone, so the output is the input.
    def self.from_left(left)
      profile = Profiles.find(left.profile)
      return nil unless profile && left.measured_lra

      new(integrated: left.measured_i, lra: left.measured_lra, target: profile[:lufs], basis: :computed)
    end
    private_class_method :from_stamp, :from_left

    def deviation = (integrated - target).abs
  end

  # The share of files you could watch without reaching for the remote: within
  # `within_lu` of their target loudness and at or under `lra_limit` of
  # loudness range. A file whose final levels are unknown is not guessed at; it
  # is counted apart, so the rate is over files that could be judged.
  class RemoteFreeRate
    WITHIN_LU = 2.0
    LRA_LIMIT = 12.0

    attr_reader :within_lu, :lra_limit

    # levels_per_file: file => FinalLevels, or nil where they are not known.
    def initialize(levels_per_file, within_lu: WITHIN_LU, lra_limit: LRA_LIMIT)
      @within_lu = within_lu.to_f
      @lra_limit = lra_limit.to_f
      @levels = levels_per_file
    end

    def remote_free?(levels) = level_ok?(levels) && range_ok?(levels)

    def level_ok?(levels) = levels && levels.deviation <= within_lu
    def range_ok?(levels) = levels && levels.lra <= lra_limit

    def judged = @levels.values.compact
    def not_judged = @levels.values.count(&:nil?)
    def remote_free = judged.count { |levels| remote_free?(levels) }
    def off_level = judged.count { |levels| !level_ok?(levels) }
    def wide_range = judged.count { |levels| !range_ok?(levels) }
    def measured = judged.count { |levels| levels.basis == :measured }

    # Fraction 0.0..1.0, or nil when no file could be judged.
    def rate = judged.empty? ? nil : remote_free.fdiv(judged.size)

    # The rate if every file that couldn't be judged would fail: what the library can be sure of.
    def floor = @levels.empty? ? nil : remote_free.fdiv(@levels.size)

    def to_h
      { rate: rate&.round(4), floor: floor&.round(4), remote_free: remote_free, judged: judged.size, not_judged: not_judged,
        off_level: off_level, wide_range: wide_range, measured: measured,
        within_lu: within_lu, lra_limit: lra_limit }
    end

    def summary
      return "Remote-free rate: n/a (no file could be judged#{not_judged_note})" unless rate

      "Remote-free rate: #{(rate * 100).round(1)}% (#{remote_free} of #{judged.size} judged files within #{within_lu} LU " \
        "of target and LRA <= #{lra_limit}; #{basis_note}#{not_judged_note}#{floor_note})"
    end

    private

    def basis_note
      return 'measured' if measured == judged.size
      return 'computed from records' if measured.zero?

      "#{measured} measured, rest computed"
    end

    def not_judged_note = not_judged.positive? ? "; #{not_judged} not judged, no levels on record (--measure reads them)" : ''
    def floor_note = not_judged.positive? ? "; at worst #{(floor * 100).round(1)}% of all #{@levels.size} files" : ''
  end
end
