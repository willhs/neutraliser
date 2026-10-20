require 'time'

module Neutraliser
  # What neutraliser did to a file, recorded inside the file itself as
  # NEUTRALISER_* metadata tags. Unlike the `.neutraliser` sidecar it travels
  # with the file: moving it, or running from a different root, keeps the
  # record. This is the ONE place that knows the tag names and their string
  # encoding (both directions). Schema: docs/ops/data_contracts.md.
  #
  # mode is 'linear' (constant gain), 'limited' (constant gain plus a peak
  # limiter, --limit-db) or 'dynamic' (loudnorm compressed the dynamic range).
  # gain_db is only meaningful for linear and limited; measured_* are the
  # pre-normalisation loudnorm values, absent in --fast mode (no analysis).
  Stamp = Data.define(:version, :profile, :mode, :gain_db, :source_codec, :source_bitrate,
                      :measured_i, :measured_tp, :measured_lra, :date)

  class Stamp
    def self.tag_name(field) = "NEUTRALISER_#{field.upcase}"

    FLOAT_FIELDS = %i[gain_db measured_i measured_tp measured_lra].freeze

    # Builds a Stamp from probed tags (stream or container level). Tag-name
    # case varies by container, so keys are matched case-insensitively.
    # Returns nil when the file carries no neutraliser record.
    def self.from_tags(tags)
      tags = (tags || {}).transform_keys { |key| key.to_s.upcase }
      values = members.to_h { |field| [field, tags[tag_name(field)].to_s.strip] }
      return nil if values[:profile].empty?

      new(**values.to_h { |field, value| [field, decode(field, value)] })
    end

    def self.decode(field, value)
      return nil if value.empty?
      return value.to_f if FLOAT_FIELDS.include?(field)
      return value.to_i if field == :source_bitrate

      value
    end

    def self.now(**fields)
      new(version: VERSION, date: Time.now.utc.iso8601, **fields)
    end

    # Every field is always written: an empty value makes ffmpeg delete the
    # key, so a stale tag carried over from an earlier run by -map_metadata
    # (e.g. a linear GAIN_DB on a file now re-done dynamic) can't survive.
    def to_tags
      to_h.to_h do |field, value|
        encoded = value.is_a?(Float) ? format('%.2f', value) : value.to_s
        [self.class.tag_name(field), encoded]
      end
    end

    def linear? = mode == 'linear'
    def limited? = mode == 'limited'
    def dynamic? = mode == 'dynamic'
  end
end
