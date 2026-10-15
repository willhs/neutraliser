require 'json'

module Neutraliser
  # `neutraliser report PATH`: what the files under PATH say was done to them,
  # read from their own NEUTRALISER_* tags (see Stamp). Sidecars and run
  # manifests aren't consulted — the file is the record.
  class Report
    FORMATS = %w[summary tsv json].freeze
    TSV_FIELDS = %i[profile gain_db source_codec source_bitrate measured_i measured_tp measured_lra version date].freeze

    # state is the stamp's mode ('linear' / 'dynamic'), or 'untouched' when
    # the file carries no record.
    Row = Data.define(:file, :stamp) do
      def state = stamp ? (stamp.mode || 'unknown') : 'untouched'
    end

    attr_reader :rows

    def initialize(path)
      @rows = video_files(path).map { |file| Row.new(file: file, stamp: FFmpegWrapper.read_stamp(file)) }
    end

    def counts
      states = rows.map(&:state).tally
      {
        total: rows.length,
        linear: states.fetch('linear', 0),
        dynamic: states.fetch('dynamic', 0),
        untouched: states.fetch('untouched', 0),
        profiles: rows.filter_map { |row| row.stamp&.profile }.tally.sort.to_h
      }
    end

    def summary
      c = counts
      lines = ["Files: #{c[:total]}",
               "  normalised linear:  #{c[:linear]}",
               "  normalised dynamic: #{c[:dynamic]}",
               "  untouched:          #{c[:untouched]}"]
      lines << "Profiles: #{c[:profiles].map { |name, n| "#{name}=#{n}" }.join(', ')}" if c[:profiles].any?
      lines.join("\n")
    end

    def to_tsv
      header = ['file', 'state', *TSV_FIELDS].join("\t")
      body = rows.map do |row|
        [row.file, row.state, *TSV_FIELDS.map { |field| row.stamp&.public_send(field) }].join("\t")
      end
      [header, *body].join("\n")
    end

    def to_json(*)
      files = rows.map { |row| { file: row.file, state: row.state, stamp: row.stamp&.to_h } }
      JSON.pretty_generate(summary: counts, files: files)
    end

    private

    def video_files(path)
      return [File.expand_path(path)] if File.file?(path)

      Dir.glob(File.join(path, '**', '*'))
         .select { |file| Processor::SUPPORTED_FORMATS.include?(File.extname(file).downcase) }
         .sort.map { |file| File.expand_path(file) }
    end
  end
end
