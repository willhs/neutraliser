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

    # loudnorm (libebur128 behind it) weighs the first six channels only; the 7th and 8th of a 7.1 layout
    # (the side surrounds) are dropped, so a track above this is also read with ebur128 (#with_all_channels).
    LOUDNORM_CHANNELS = 6

    # The `channels:` keyword for FFmpegWrapper.measure_loudness, only for a track with channels loudnorm
    # doesn't count: splat it into the call, so every other track is measured by exactly the call it always was.
    def self.side_channels(track)
      track[:channels].to_i > LOUDNORM_CHANNELS ? { channels: track[:channels] } : {}
    end

    attr_reader :input_i, :input_tp, :input_lra, :input_thresh, :target_offset

    # Seconds of audio the read got through, when it was asked to track that (nil otherwise, and from a
    # cache). Not cached and not part of ==: it describes this read, not the file.
    attr_reader :read_seconds

    # This measurement noting how many seconds of audio the read got through.
    def with_read_seconds(seconds)
      dup.tap { |copy| copy.read_seconds = seconds }
    end

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
        target_offset: hash['target_offset'].to_f,
        silent: hash['silent'] == true
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

    # This measurement with the figures ebur128 read over every channel put in place of loudnorm's, which
    # only counts six (finding 14 of research 0003; the range, finding 5 of the 15 Nov review). Integrated
    # loudness, its gate and the range come from ebur128; the peak is the higher of the two; target_offset
    # follows the new loudness. The range matters as much as the level: loud or quiet passages that live
    # only in the side surrounds widen it, and rung 3 of the ladder decides on it. Every read of a track
    # above six channels goes through here, candidate compressions included, so ebur128's range is
    # compared with ebur128's and the tolerance means the same before and after. Both meters follow the
    # EBU Tech 3342 definition, so on six channels or under they agree within about half a LU; a nil
    # range (the summary did not print one) keeps loudnorm's.
    # A silent measurement stays silent (ebur128 reads it as -inf too).
    #
    # `target_offset` is not "target minus loudness". loudnorm's `offset=` is the extra gain its dynamic
    # mode adds (its own linear mode ignores it and works the gain out from measured_I), and its own read
    # reports about 0. A track that goes dynamic (--allow-dynamic, the night profile, a file that does not
    # fit linear) lands on the target as loudnorm hears it, six channels, so the offset carries only the
    # gap between the two readings: the side channels' share, which the dynamic pass cannot hear.
    # (Taking target - integrated here added the whole gain a second time: a 7.1 clip came out 14 dB over.)
    def with_all_channels(integrated:, threshold:, true_peak:, range: nil)
      return self if silent? || integrated.nil? || !integrated.finite?

      self.class.new(
        input_i: integrated, input_tp: [input_tp, true_peak || input_tp].max, input_lra: range&.finite? ? range : input_lra,
        input_thresh: threshold || input_thresh, target_offset: target_offset + (input_i - integrated)
      )
    end

    def already_at_target?
      @already_at_target
    end

    # True when loudnorm measured no signal at all (input_i was "-inf").
    def silent?
      @silent
    end

    def needs_normalization?(target_profile, tolerance: 1.0)
      return false if already_at_target? || silent?

      (input_i - target_profile[:lufs]).abs > tolerance
    end

    # Sidecar cache representation — the single place that knows which fields
    # are persisted.
    def to_cache_h
      fields = {
        'input_i' => input_i,
        'input_tp' => input_tp,
        'input_lra' => input_lra,
        'input_thresh' => input_thresh,
        'target_offset' => target_offset
      }
      silent? ? fields.merge('silent' => true) : fields
    end

    def ==(other)
      other.is_a?(Measurement) && to_cache_h == other.to_cache_h && already_at_target? == other.already_at_target?
    end

    protected

    attr_writer :read_seconds
  end
end
