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
  # Reading the files also gives each one's dialogue figures (see Dialogue) and a
  # second rate anchored on dialogue (see DialogueRate), read-only, beside the first;
  # pass `dialogue_anchor: nil` to skip that extra read.
  class Report
    FORMATS = %w[summary tsv json].freeze
    RECORD_FIELDS = %i[profile recipe gain_db source_codec source_bitrate measured_i measured_tp measured_lra
                       compression centre_boost_db lra_after source_dialnorm].freeze
    TSV_FIELDS = (RECORD_FIELDS + %i[version date]).freeze
    OUTPUT_FIELDS = %w[output_i output_lra output_basis remote_free].freeze
    DIALOGUE_FIELDS = %w[dialogue_i dialogue_method dialogue_confidence speech_share ldr dialnorm dialogue_remote_free].freeze

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
                   lra_limit: RemoteFreeRate::LRA_LIMIT, dialogue_anchor: DialogueAnchor::DEFAULT)
      @measure = measure
      @profile = profile
      @within_lu = within_lu
      @lra_limit = lra_limit
      deciders = {}
      sources = {}
      @rows = video_files(path).map do |file|
        source = sources[file] = Source.new(file)
        stamp = source.stamp
        Row.new(file: file, stamp: stamp, left: stamp ? nil : SkipDecider.left_record_for(file, deciders))
      end
      # Judged now, not on first use: a caller may delete the files (the rate harness does) once built.
      @final_levels = {}
      @dialogue = {}
      rows.each { |row| judge(row, sources.fetch(row.file), dialogue_anchor) }
      @rate = RemoteFreeRate.new(@final_levels, within_lu: @within_lu, lra_limit: @lra_limit)
      @dialogue_rate = DialogueRate.new(@dialogue, anchor: dialogue_anchor, within_lu: @within_lu) if dialogue_anchor && @measure
    end

    def counts
      states = rows.map(&:state).tally
      {
        total: rows.length,
        linear: states.fetch(Mode::LINEAR.to_s, 0),
        limited: states.fetch(Mode::LIMITED.to_s, 0),
        compressed: states.fetch(Mode::COMPRESSED.to_s, 0),
        dynamic: states.fetch(Mode::DYNAMIC.to_s, 0),
        untouched: states.fetch('untouched', 0),
        profiles: rows.filter_map { |row| row.stamp&.profile }.tally.sort.to_h,
        recipes: rows.filter_map(&:recipe_label).tally.sort_by { |label, _| label }.to_h,
        dialnorms: rows.filter_map { |row| row.stamp&.source_dialnorm }.tally.sort.to_h,
        left: rows.filter_map { |row| row.left&.reason }.tally.sort.to_h
      }
    end

    # The remote-free rate over all files under the path.
    attr_reader :rate

    # The same files judged on dialogue (DialogueRate); nil unless the files were read for it.
    attr_reader :dialogue_rate

    # file => Dialogue, or nil where the file couldn't be measured.
    def dialogue_for(row) = @dialogue[row.file]

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
      lines.concat(dialogue_rate.summary_lines) if dialogue_rate
      lines.join("\n")
    end

    def to_tsv
      header = ['file', 'state', *TSV_FIELDS, 'left_reason', 'left_message', *OUTPUT_FIELDS, *DIALOGUE_FIELDS].join("\t")
      body = rows.map do |row|
        levels = @final_levels[row.file]
        [row.file, row.state, *TSV_FIELDS.map { |field| row.value(field) }, row.left&.reason, row.left&.message,
         levels&.integrated&.round(2), levels&.lra&.round(2), levels&.basis, levels && rate.remote_free?(levels),
         *dialogue_tsv(row)].join("\t")
      end
      [header, *body].join("\n")
    end

    def to_json(*)
      files = rows.map do |row|
        { file: row.file.scrub, state: row.state, stamp: row.stamp&.to_h, left: row.left&.to_h, output: output_h(row),
          dialogue: dialogue_h(row) }.compact
      end
      summary = counts.merge(remote_free_rate: rate.to_h)
      summary[:dialogue_remote_free_rate] = dialogue_rate.to_h if dialogue_rate
      JSON.pretty_generate(summary: summary, files: files)
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

    # One-line words for a row's dialogue figures, or nil when the files weren't read for them.
    def dialogue_text(row)
      return unless dialogue_rate

      dialogue = dialogue_for(row)
      return 'dialogue: not measured' unless dialogue
      return "dialogue: n/a (#{dialogue.estimate.reason})" unless dialogue.judged?

      estimate = dialogue.estimate
      text = format('dialogue %.1f LUFS (%s, %s confidence), programme %.1f LU above it', estimate.level,
                    estimate.method.to_s.tr('_', ' '), estimate.confidence, dialogue.ldr)
      dialogue.dialnorm ? "#{text}, dialnorm #{dialogue.dialnorm}#{' (the encoder default, likely unset)' if dialogue.dialnorm == DolbyStream::UNSET}" : text
    end

    def dialogue_verdict_text(row)
      verdict = dialogue_rate&.verdict(dialogue_for(row))
      return 'dialogue not judged' if verdict.nil?

      verdict ? 'dialogue-anchored remote-free' : 'off the dialogue anchor'
    end

    private

    def dialogue_h(row)
      dialogue = dialogue_for(row)
      return unless dialogue

      estimate = dialogue.estimate
      { programme_i: dialogue.programme.round(2), dialogue_i: estimate.level&.round(2), method: estimate.method&.to_s,
        confidence: estimate.confidence&.to_s, speech_share: estimate.speech_share, reason: estimate.reason,
        loudness_above_dialogue: dialogue.ldr&.round(2), dialnorm: dialogue.dialnorm,
        remote_free: dialogue_rate.verdict(dialogue) }
    end

    def dialogue_tsv(row)
      dialogue = dialogue_for(row)
      return Array.new(DIALOGUE_FIELDS.size) unless dialogue

      estimate = dialogue.estimate
      [estimate.level&.round(2), estimate.method, estimate.confidence, estimate.speech_share, dialogue.ldr&.round(2),
       dialogue.dialnorm, dialogue_rate.verdict(dialogue)]
    end

    def output_h(row)
      levels = final_levels_for(row)
      levels&.to_h&.merge(remote_free: rate.remote_free?(levels))
    end

    # Fills @final_levels (and @dialogue, when the files are read) for one row. Judged at construction, not on
    # first use: a caller may delete the files (the rate harness does) once built.
    def judge(row, source, anchor)
      return @final_levels[row.file] = FinalLevels.computed(stamp: row.stamp, left: row.left) unless @measure

      track = source.primary_track
      levels = measured_levels(row, track)
      @final_levels[row.file] = levels
      @dialogue[row.file] = dialogue_of(row, track, levels) if anchor && levels
    rescue FFmpegError => e
      Neutraliser.logger.log "  Could not measure #{row.file}: #{e.message}"
      @final_levels[row.file] = nil unless @final_levels.key?(row.file) # a failed dialogue read keeps the programme figure
      @dialogue[row.file] = nil if anchor
    end

    def measured_levels(row, track)
      target = (Profiles.find(row.record&.profile) || @profile)[:lufs]
      measurement = FFmpegWrapper.measure_loudness(row.file, target_i: target, audio_index: track[:index])
      FinalLevels.measured(measurement, target: target)
    end

    def dialogue_of(row, track, levels)
      Dialogue.new(programme: levels.integrated, estimate: DialogueMeter.estimate(row.file, track),
                   dialnorm: DialogueMeter.dialnorm(row.file, track, row.stamp))
    end

    def video_files(path)
      absolute = File.absolute_path(path)
      return [absolute] if File.file?(absolute)

      VideoFiles.under(absolute).sort
    end
  end
end
