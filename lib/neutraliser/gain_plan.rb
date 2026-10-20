module Neutraliser
  # The constant-gain decision for one measured file: how far the profile asks
  # to move it (desired), how far the true-peak ceiling lets it move (applied),
  # and whether a peak limiter has to hold the overshoot.
  #
  # limit_db is the most the limiter may pull peaks down (0 = strict constant
  # gain, the default): the gain may exceed the ceiling's headroom by that
  # much. Anything over the ceiling is then caught by an alimiter, which is the
  # only dynamics change on this path and is reported as mode `limited`.
  GainPlan = Data.define(:desired, :applied, :ceiling_db, :limited) do
    # A rounded gain can sit a hair over the ceiling without any real overshoot.
    OVERSHOOT_EPSILON_DB = 0.01
    # Limiter ceiling sits this far under the true-peak target, leaving room for
    # inter-sample overs (alimiter works on sample peaks).
    LIMITER_MARGIN_DB = 0.5
    LIMITER_ARGS = 'attack=5:release=50:level=0:latency=1'.freeze

    def self.for(measurement, profile, limit_db: 0.0)
      desired = profile[:lufs] - measurement.input_i
      headroom = profile[:tp] - measurement.input_tp + limit_db.to_f
      applied = [desired, headroom].min
      limited = measurement.input_tp + applied > profile[:tp] + OVERSHOOT_EPSILON_DB
      new(desired: desired, applied: applied, ceiling_db: profile[:tp], limited: limited)
    end

    # LU the ceiling leaves the output short of the profile target.
    def shortfall = (desired - applied).round(2)

    # Does re-encoding move the file towards target by at least min_gain dB?
    # Direction matters: a quiet file whose peaks already touch the ceiling
    # gets a negative gain, and turning it down is generation loss for nothing.
    def worthwhile?(min_gain)
      (desired.negative? ? -applied : applied) >= min_gain
    end

    def mode = limited ? 'limited' : 'linear'

    def filter
      chain = "volume=#{format('%.2f', applied)}dB"
      return chain unless limited

      limit = 10**((ceiling_db - LIMITER_MARGIN_DB) / 20.0)
      "#{chain},alimiter=limit=#{format('%.4f', limit)}:#{LIMITER_ARGS}"
    end
  end
end
