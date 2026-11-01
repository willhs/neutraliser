module Neutraliser
  # Opt-in compression (--lra-target). Nothing here runs unless the caller asks:
  # the default path is constant gain.
  #
  # The ladder is searched for the gentlest rung whose compressed signal measures
  # at or under the LRA target (+ tolerance). Each candidate costs one decode of
  # the file (a loudnorm measurement through the pre-chain), so the search is a
  # bisection: LRA falls monotonically down the ladder.
  module Compression
    KNEE = 4
    # acompressor's accepted threshold range (linear): -60 dB to 0 dB.
    THRESHOLD_RANGE = (0.000976563..1.0)
    # Channel layouts whose third channel is the centre (dialogue) channel.
    CENTRE_LAYOUTS = ['5.1', '5.1(side)'].freeze
    MAX_CENTRE_BOOST_DB = 12.0

    # One step of the ladder: a stronger-than-the-last acompressor setting. The
    # threshold is a dB offset from the file's own integrated loudness (not an
    # absolute level), so a rung does about the same to a quiet file as to a hot
    # one. Gentle and strong follow the A/B clips the first tests were made with
    # (2.5:1 at 6 dB under the file's level; 4:1 at 12 dB under).
    Rung = Data.define(:name, :threshold_offset_db, :ratio, :attack_ms, :release_ms) do
      def filter(reference_lufs)
        threshold = (10**((reference_lufs + threshold_offset_db) / 20.0)).clamp(THRESHOLD_RANGE.begin, THRESHOLD_RANGE.end)
        # link=maximum: one gain for every channel, which keeps a 5.1 image stable.
        "acompressor=threshold=#{format('%.5f', threshold)}:ratio=#{ratio}:attack=#{attack_ms}:release=#{release_ms}" \
          ":knee=#{KNEE}:detection=rms:link=maximum"
      end
    end

    LADDER = [
      Rung.new(name: 'gentle',   threshold_offset_db: -6,  ratio: 2.5, attack_ms: 20, release_ms: 300),
      Rung.new(name: 'moderate', threshold_offset_db: -9,  ratio: 3.0, attack_ms: 15, release_ms: 275),
      Rung.new(name: 'strong',   threshold_offset_db: -12, ratio: 4.0, attack_ms: 10, release_ms: 250),
      Rung.new(name: 'heavy',    threshold_offset_db: -16, ratio: 5.0, attack_ms: 10, release_ms: 250),
      Rung.new(name: 'severe',   threshold_offset_db: -20, ratio: 6.0, attack_ms: 10, release_ms: 250),
      Rung.new(name: 'extreme',  threshold_offset_db: -24, ratio: 8.0, attack_ms: 10, release_ms: 250)
    ].freeze

    # What --lra-target decided for one file: the rung (gentlest that reaches the
    # target, else the strongest), the centre boost actually applied, the
    # measurement before and after the pre-chain, and the constant-gain plan that
    # levels the compressed signal to the profile target.
    #
    # Answers the same questions as GainPlan (mode, filter, applied, shortfall), so
    # FFmpegWrapper.apply_normalization treats the two alike.
    Plan = Data.define(:rung, :centre_boost_db, :before, :after, :lra_target, :reached, :gain_plan, :chain) do
      def mode = 'compressed'
      def filter = "#{chain},#{gain_plan.filter}"
      def applied = gain_plan.applied
      def shortfall = gain_plan.shortfall
      def limited = gain_plan.limited
      def reached? = reached

      # The stamp's `compression` value: the rung, plus whether the peak limiter
      # (--limit-db) also had to hold the overshoot after levelling.
      def label = limited ? "#{rung.name}+limiter" : rung.name

      # What the stamp records beyond the normalisation fields.
      def stamp_fields = { compression: label, centre_boost_db: centre_boost_db, lra_after: after.input_lra }
    end

    module_function

    def needed?(measurement, lra_target:, tolerance:)
      !measurement.silent? && !measurement.already_at_target? && measurement.input_lra > lra_target + tolerance
    end

    # Does the track have a centre channel this module knows how to find?
    def centre_channel?(track)
      CENTRE_LAYOUTS.include?(track[:channel_layout])
    end

    # The centre boost as a pan filter that leaves every other channel alone, or
    # nil. The layout is kept as the source has it.
    def centre_boost_filter(track, boost_db)
      return nil unless boost_db.to_f.positive? && centre_channel?(track)

      gain = format('%.4f', 10**(boost_db / 20.0))
      "pan=#{track[:channel_layout]}|c0=c0|c1=c1|c2=#{gain}*c2|c3=c3|c4=c4|c5=c5"
    end

    # Measures the file through candidate chains (FFmpegWrapper.measure_loudness
    # with a pre_filter) and returns the Plan. `before` is the original
    # measurement. The file is not changed.
    def plan(path, track, before, profile, lra_target:, tolerance:, centre_boost_db: 0.0, limit_db: 0.0)
      boost = centre_boost_filter(track, centre_boost_db)
      chain_for = ->(rung) { [boost, rung.filter(before.input_i)].compact.join(',') }
      measured = {}
      measure = lambda do |index|
        measured[index] ||= FFmpegWrapper.measure_loudness(
          path, target_i: profile[:lufs], target_tp: profile[:tp], target_lra: profile[:lra],
                audio_index: track[:index], pre_filter: chain_for.call(LADDER[index])
        )
      end

      index = first_rung_within(lra_target + tolerance, measure)
      reached = !index.nil?
      index ||= LADDER.length - 1
      after = measure.call(index)

      Plan.new(
        rung: LADDER[index], centre_boost_db: boost ? centre_boost_db.to_f : 0.0, before: before, after: after,
        lra_target: lra_target, reached: reached, chain: chain_for.call(LADDER[index]),
        gain_plan: GainPlan.for(after, profile, limit_db: limit_db)
      )
    end

    # Bisection for the lowest rung whose measured LRA is at or under `limit`, or
    # nil when even the strongest is over it.
    def first_rung_within(limit, measure)
      low = 0
      high = LADDER.length
      while low < high
        mid = (low + high) / 2
        if measure.call(mid).input_lra <= limit
          high = mid
        else
          low = mid + 1
        end
      end
      low == LADDER.length ? nil : low
    end
  end
end
