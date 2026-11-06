module Neutraliser
  # How a file's level was changed. One value, one spelling: the stamp's tag value
  # (`to_s`, 'linear'), the run manifest and the log's capitalised word (`label`,
  # 'Linear') both come from here, so nothing re-spells it with capitalize/downcase.
  #
  # linear     - constant gain
  # limited    - constant gain plus a peak limiter (--limit-db)
  # compressed - acompressor, then constant gain (--lra-target)
  # dynamic    - loudnorm compressed the dynamic range
  # unknown    - loudnorm's summary named no mode (the stamp keeps the predicted one)
  Mode = Data.define(:name) do
    def to_s = name
    def label = name.capitalize
  end

  # (The five modes, and reading one back from text.)
  class Mode
    LINEAR = new(name: 'linear')
    LIMITED = new(name: 'limited')
    COMPRESSED = new(name: 'compressed')
    DYNAMIC = new(name: 'dynamic')
    UNKNOWN = new(name: 'unknown')
    ALL = [LINEAR, LIMITED, COMPRESSED, DYNAMIC, UNKNOWN].freeze

    # nil for text that names no mode. Case-insensitive: ffmpeg's summary says
    # "Linear", a tag says 'linear'.
    def self.parse(text) = ALL.find { |mode| mode.name == text.to_s.strip.downcase }
  end
end
