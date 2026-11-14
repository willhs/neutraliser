module Neutraliser
  # A file another engine already levelled: the retired neutralise.sh, whose
  # manifest `import-manifest` carries over. It wrote no NEUTRALISER_* tags, so
  # the `.neutraliser` sidecar entry (`source`, `source_status`) is the only
  # record, and `report` counts these as `imported`, not `untouched`.
  ImportedRecord = Data.define(:source, :status) do
    def self.from_shell(status) = new(source: 'neutralise.sh', status: status)

    def self.from_entry(hash)
      return nil unless hash.is_a?(Hash) && hash['source'].is_a?(String)

      new(source: hash['source'], status: hash['source_status'])
    end

    def to_h_compact = to_h.compact
  end
end
