require 'json'

module Neutraliser
  # Carries the history of the retired neutralise.sh over: its append-only
  # manifest.jsonl is the only record that those files were already leveled
  # (the shell never wrote NEUTRALISER_* tags). Without this, the first sweep
  # by the CLI would re-measure the whole library, ~20 minutes a movie.
  #
  # An entry counts as "processed" when the script finished with the file
  # (`done`, or skipped it as within tolerance / peak-capped) and the file
  # still has the size and mtime the entry recorded. Each hit lands in the
  # `.neutraliser` sidecar beside the file, which a run over that folder (or
  # over the file alone) reads. Failures, rollbacks, disk-guard, codec and
  # object-audio entries are not imported: the CLI decides those afresh.
  class ManifestImport
    IMPORTABLE = %w[done skip_tol skip_tp_capped].freeze

    Result = Data.define(:imported, :changed, :missing, :legacy, :ignored)

    # root is the directory the manifest's relative `file` paths hang off
    # (neutralise.sh's MEDIA_HOST, e.g. /volume1/media).
    def initialize(manifest_path, root:, profile:, trust_legacy: false, dry_run: false)
      @manifest_path = manifest_path
      @root = root
      @profile = profile
      @trust_legacy = trust_legacy
      @dry_run = dry_run
    end

    def run
      counts = Hash.new(0)
      deciders = {}
      latest_entries.each_value do |entry|
        outcome = classify(entry)
        counts[outcome] += 1
        next unless outcome == :imported && !@dry_run

        path = File.join(@root, entry['file'])
        deciders[File.dirname(path)] ||= SkipDecider.new(File.dirname(path), fast_verification: false)
        deciders[File.dirname(path)].mark_processed(path, @profile)
      end
      Result.new(**Result.members.to_h { |key| [key, counts[key]] })
    end

    private

    # The manifest is an append-only log, last write wins.
    def latest_entries
      entries = {}
      File.foreach(@manifest_path) do |line|
        entry = JSON.parse(line)
        entries[entry['file']] = entry if entry['file']
      rescue JSON::ParserError
        next
      end
      entries
    end

    def classify(entry)
      return :ignored unless IMPORTABLE.include?(entry['status'])

      path = File.join(@root, entry['file'])
      return :missing unless File.file?(path)
      return(@trust_legacy ? :imported : :legacy) unless entry['size'] && entry['mtime']

      File.size(path) == entry['size'] && File.mtime(path).to_i == entry['mtime'] ? :imported : :changed
    end
  end
end
