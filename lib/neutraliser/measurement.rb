module Neutraliser
  # Typed result of a loudnorm measurement pass. Replaces the raw ffmpeg JSON
  # hash (string-valued input_i/input_tp/input_lra/input_thresh/target_offset)
  # that used to travel between FFmpegWrapper, CacheManager, AudioAnalyser and
  # Processor, with every reader re-doing its own .to_f.
  #
  # This is the ONE place that knows the loudnorm JSON keys and the ONE place
  # that knows the sidecar cache's on-disk shape — both directions of the
  # conversion (from ffmpeg / from cache, and to cache) live here.
  class Measurement
    CACHE_KEYS = %w[input_i input_tp input_lra input_thresh target_offset].freeze

    attr_reader :input_i, :input_tp, :input_lra, :input_thresh, :target_offset

    # Builds a Measurement from ffmpeg's loudnorm print_format=json output.
    #
    # loudnorm prints "-inf" for input_i when it heard nothing (digital silence,
    # or a stream that returned no audio). String#to_f turns "-inf" into 0.0,
    # which reads as a very LOUD file, so that case is flagged `silent?` and
    # callers that report levels must not use input_i.
    def self.from_loudnorm_json(json)
      new(
        input_i: json['input_i'].to_f,
        input_tp: json['input_tp'].to_f,
        input_lra: json['input_lra'].to_f,
        input_thresh: json['input_thresh'].to_f,
        target_offset: json['target_offset'].to_f,
        silent: !finite_number?(json['input_i'])
      )
    end

    def self.finite_number?(value)
      Float(value).finite?
    rescue ArgumentError, TypeError
      false
    end
    private_class_method :finite_number?

    # Rebuilds a Measurement from a sidecar cache hash. Returns nil when the
    # hash doesn't carry a full set of loudnorm fields (corrupt/legacy cache),
    # so callers can treat it the same as a cache miss.
    def self.from_cache_h(hash)
      return nil unless hash.is_a?(Hash) && CACHE_KEYS.all? { |key| hash.key?(key) }

      new(
        input_i: hash['input_i'].to_f,
        input_tp: hash['input_tp'].to_f,
        input_lra: hash['input_lra'].to_f,
        input_thresh: hash['input_thresh'].to_f,
        target_offset: hash['target_offset'].to_f
      )
    end

    # An explicit "already at target" state, used when fast verification
    # (cache hit, processing marker, or quick sample) determines normalization
    # isn't needed without a full measurement pass. Unlike the old
    # Processor#create_target_level_data, this doesn't fabricate an
    # input_thresh — #needs_normalization? short-circuits to false instead of
    # relying on invented numbers happening to land within tolerance.
    def self.already_at_target(profile)
      new(
        input_i: profile[:lufs],
        input_tp: profile[:tp],
        input_lra: profile[:lra],
        input_thresh: nil,
        target_offset: 0.0,
        already_at_target: true
      )
    end

    def initialize(input_i:, input_tp:, input_lra:, input_thresh:, target_offset:, already_at_target: false,
                   silent: false)
      @input_i = input_i
      @input_tp = input_tp
      @input_lra = input_lra
      @input_thresh = input_thresh
      @target_offset = target_offset
      @already_at_target = already_at_target
      @silent = silent
    end

    def already_at_target?
      @already_at_target
    end

    # True when loudnorm measured no signal at all (input_i was "-inf").
    def silent?
      @silent
    end

    def needs_normalization?(target_profile, tolerance: 1.0)
      return false if already_at_target?

      (input_i - target_profile[:lufs]).abs > tolerance
    end

    # Sidecar cache representation — the single place that knows which fields
    # are persisted.
    def to_cache_h
      {
        'input_i' => input_i,
        'input_tp' => input_tp,
        'input_lra' => input_lra,
        'input_thresh' => input_thresh,
        'target_offset' => target_offset
      }
    end

    def ==(other)
      other.is_a?(Measurement) && to_cache_h == other.to_cache_h && already_at_target? == other.already_at_target?
    end
  end
end
