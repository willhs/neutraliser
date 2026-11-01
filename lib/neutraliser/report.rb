require 'json'

module Neutraliser
  # `neutraliser report PATH`: what the files under PATH say was done to them,
  # read from their own NEUTRALISER_* tags (see Stamp). A file with no tags is
  # untouched; if a run looked at it and left it alone on purpose, the
  # `.neutraliser` sidecar says why (see LeftRecord), and that is the one thing
  # read from a sidecar. Run manifests aren't consulted.
  #
  # It also judges the library: the remote-free rate (see RemoteFreeRate), from
  # what the records say happened, or from reading each file when `measure:`.
  class Report
    FORMATS = %w[summary tsv json].freeze
    RECORD_FIELDS = %i[profile recipe gain_db source_codec source_bitrate measured_i measured_tp measured_lra
                       compression centre_boost_db lra_after source_dialnorm].freeze
    TSV_FIELDS = (RECORD_FIELDS + %i[version date]).freeze
    OUTPUT_FIELDS = %w[output_i output_lra output_basis remote_free].freeze

    # state is the stamp's mode ('linear' / 'limited' / 'compressed' / 'dynamic'), or 'untouched' when
    # the file carries no record. left says why an untouched file was left alone, if known.
    Row = Data.define(:file, :stamp, :left) do
      def state = stamp ? (stamp.mode || 'unknown') : 'untouched'
      def record = stamp || left
      def recipe_label = stamp ? Recipe.label(stamp.recipe) : nil

      # A field of the stamp, else of the left record where it has one (its measured levels).
      def value(field) = record.respond_to?(field) ? record.public_send(field) : nil
    end

    attr_reader :rows

    # profile: the target an untouched file with no record is judged against.
    def initialize(path, measure: false, profile: Profiles.default_profile, within_lu: RemoteFreeRate::WITHIN_LU,
                   lra_limit: RemoteFreeRate::LRA_LIMIT)
      @measure = measure
      @profile = profile
      @within_lu = within_lu
      @lra_limit = lra_limit
      deciders = {}
      @rows = video_files(path).map do |file|
        stamp = FFmpegWrapper.read_stamp(file)
        Row.new(file: file, stamp: stamp, left: stamp ? nil : SkipDecider.left_record_for(file, deciders))
      end
      # Judged now, not on first use: a caller may delete the files (the rate harness does) once built.
      @final_levels = rows.to_h { |row| [row.file, levels_for(row)] }
      @rate = RemoteFreeRate.new(@final_levels, within_lu: @within_lu, lra_limit: @lra_limit)
    end

    def counts
      states = rows.map(&:state).tally
      {
        total: rows.length,
        linear: states.fetch('linear', 0),
        limited: states.fetch('limited', 0),
        compressed: states.fetch('compressed', 0),
        dynamic: states.fetch('dynamic', 0),
        untouched: states.fetch('untouched', 0),
        profiles: rows.filter_map { |row| row.stamp&.profile }.tally.sort.to_h,
        recipes: rows.filter_map(&:recipe_label).tally.sort_by { |label, _| label }.to_h,
        dialnorms: rows.filter_map { |row| row.stamp&.source_dialnorm }.tally.sort.to_h,
        left: rows.filter_map { |row| row.left&.reason }.tally.sort.to_h
      }
    end

    # The remote-free rate over all files under the path.
    attr_reader :rate

    def summary
      c = counts
      lines = ["Files: #{c[:total]}",
               "  normalised linear:  #{c[:linear]}",
               "  normalised limited: #{c[:limited]}",
               "  normalised dynamic: #{c[:dynamic]}",
               "  untouched:          #{c[:untouched]}"]
      lines.insert(3, "  normalised compressed: #{c[:compressed]}") if c[:compressed].positive?
      lines << "    left alone: #{c[:left].map { |reason, n| "#{reason}=#{n}" }.join(', ')}" if c[:left].any?
      lines << "Profiles: #{c[:profiles].map { |name, n| "#{name}=#{n}" }.join(', ')}" if c[:profiles].any?
      lines << "Recipes: #{c[:recipes].map { |label, n| "#{label}=#{n}" }.join(', ')}" if c[:recipes].any?
      lines << "Dialnorm carried over (dB): #{c[:dialnorms].map { |db, n| "#{db}=#{n}" }.join(', ')}" if c[:dialnorms].any?
      lines << rate.summary
      lines.join("\n")
    end

    def to_tsv
      header = ['file', 'state', *TSV_FIELDS, 'left_reason', 'left_message', *OUTPUT_FIELDS].join("\t")
      body = rows.map do |row|
        levels = @final_levels[row.file]
        [row.file, row.state, *TSV_FIELDS.map { |field| row.value(field) }, row.left&.reason, row.left&.message,
         levels&.integrated&.round(2), levels&.lra&.round(2), levels&.basis, levels && rate.remote_free?(levels)].join("\t")
      end
      [header, *body].join("\n")
    end

    def to_json(*)
      files = rows.map do |row|
        { file: row.file.scrub, state: row.state, stamp: row.stamp&.to_h, left: row.left&.to_h, output: output_h(row) }
      end
      JSON.pretty_generate(summary: counts.merge(remote_free_rate: rate.to_h), files: files)
    end

    # The levels the rate judged this row by, or nil when none are known.
    def final_levels_for(row) = @final_levels[row.file]

    # One-line words for a row, for a person reading a list of them.
    def state_text(row) = row.left ? "#{row.state} (#{row.left.reason})" : row.state

    def levels_text(row)
      levels = final_levels_for(row)
      return 'no levels on record' unless levels

      format('%.1f LUFS (target %.1f), LRA %.1f, %s', levels.integrated, levels.target, levels.lra, levels.basis)
    end

    def verdict_text(row)
      levels = final_levels_for(row)
      return 'not judged' unless levels

      rate.remote_free?(levels) ? 'remote-free' : 'needs the remote'
    end

    private

    def output_h(row)
      levels = final_levels_for(row)
      levels&.to_h&.merge(remote_free: rate.remote_free?(levels))
    end

    def levels_for(row)
      return FinalLevels.computed(stamp: row.stamp, left: row.left) unless @measure

      measured_levels(row)
    end

    def measured_levels(row)
      target = (Profiles.find(row.record&.profile) || @profile)[:lufs]
      measurement = FFmpegWrapper.measure_loudness(row.file, target_i: target, audio_index: FFmpegWrapper.primary_audio_index(row.file))
      FinalLevels.measured(measurement, target: target)
    rescue FFmpegError => e
      Neutraliser.logger.log "  Could not measure #{row.file}: #{e.message}"
      nil
    end

    def video_files(path)
      absolute = File.absolute_path(path)
      return [absolute] if File.file?(absolute)

      VideoFiles.under(absolute).sort
    end
  end
end
