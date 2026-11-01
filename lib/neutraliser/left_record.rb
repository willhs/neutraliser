module Neutraliser
  # Why a file was looked at and deliberately left as it is: peak-limited (the
  # peak ceiling leaves too little gain to be worth a re-encode), object audio
  # (Atmos / DTS:X would be flattened), a codec change (DTS / TrueHD cannot be
  # kept) or within tolerance (already close enough). A stamp can only be
  # written by re-encoding, and these files are not re-encoded, so the record
  # lives in the `.neutraliser` sidecar instead.
  #
  # Except for within tolerance it is a different fact from "done": it never
  # makes a later run skip the file (a flag such as --limit-db or
  # --allow-codec-change can change the answer), which is why its sidecar entry
  # has no top-level `profile`, the key that SkipDecider matches on. Normalising
  # the file later overwrites the entry. A within-tolerance record rides inside
  # the entry that does mark the file processed, there to keep its levels.
  #
  # measured_* are the file's loudnorm levels when the skip came after an
  # analysis (peak-limited, within tolerance); the object-audio and codec checks
  # run before one, so they are nil there.
  LeftRecord = Data.define(:reason, :profile, :recipe, :message, :measured_i, :measured_tp, :measured_lra) do
    def self.for(reason, profile, message: nil, measurement: nil)
      new(reason: reason.to_s, profile: profile[:name], recipe: Recipe::CURRENT, message: message,
          measured_i: measurement&.input_i, measured_tp: measurement&.input_tp, measured_lra: measurement&.input_lra)
    end

    def self.from_entry(hash)
      return nil unless hash.is_a?(Hash) && hash['left'].is_a?(Hash)

      left = hash['left']
      new(reason: left['reason'].to_s, profile: left['profile'], recipe: left['recipe'], message: left['message'],
          measured_i: left['measured_i'], measured_tp: left['measured_tp'], measured_lra: left['measured_lra'])
    end

    # Only the fields that have a value, so the sidecar stays small.
    def to_h_for_entry = to_h.compact.transform_keys(&:to_s)

    def measured? = !measured_i.nil?
  end
end
