module Neutraliser
  # What neutraliser needs to know about the loudness metadata inside an AC-3 /
  # E-AC-3 track, so a constant-gain run changes the level and nothing else.
  #
  # Two words in the stream move the level a player produces without touching the
  # samples. FFmpeg's decoder applies the dynamic-range words by default and its
  # encoders write none back, so decoding with them on bakes the compression into
  # the new track for good: DRC_OFF is the decoder setting that stops it. Its
  # encoders also write dialnorm -31 unless told otherwise, so a re-encode loses the
  # source's attenuation: dialnorm reads the source's value so the encoder can be
  # given it back.
  module DolbyStream
    CODECS = %w[ac3 eac3].freeze
    ENCODERS = %w[ac3 eac3].freeze

    # Input options, ahead of -i. FFmpeg ignores a decoder option that no stream uses
    # (a warning on stderr, never an error: checked on 4.2.2 and 7.1), so non-Dolby
    # tracks and remote streams, whose codec isn't known before the decode, can take it too.
    DRC_OFF = %w[-drc_scale 0].freeze

    SYNC_WORD = 0x0B77
    DIALNORM_BITS = 5
    UNSET = -31 # code 0 is reserved and decoders treat it as 31
    # An E-AC-3 stream may open with dependent substreams' frames before an independent one.
    EAC3_FRAMES_TO_SKIP = 8

    def self.dolby_codec?(codec) = CODECS.include?(codec.to_s.downcase)
    def self.dolby_encoder?(encoder) = ENCODERS.include?(encoder.to_s)

    # The raw-stream format ffmpeg writes a track of this codec as, for dialnorm to read.
    def self.raw_format(codec) = codec.to_s.downcase

    # dialnorm, in dB (-31 to -1), of the first independent frame in a raw AC-3 or E-AC-3
    # stream; nil when the bytes aren't one. Reads bits only, so it cannot be fooled by
    # a CRC and does no validation of its own.
    def self.dialnorm(bytes)
      bits = bytes.to_s.b.unpack1('B*')
      offset = 0
      (EAC3_FRAMES_TO_SKIP + 1).times do
        frame = Frame.new(bits, offset)
        return nil unless frame.sync?
        return frame.dialnorm unless frame.eac3?
        return frame.dialnorm if frame.independent?

        offset += frame.size_bits
        return nil if offset >= bits.length
      end
      nil
    end

    # One frame's header, read as a string of '0'/'1' from `start` (a bit offset).
    class Frame
      AC3_ACMOD_AT = 16 + 16 + 8 + 5 + 3 # sync, crc1, fscod + frmsizecod, bsid, bsmod

      def initialize(bits, start)
        @bits = bits
        @start = start
      end

      def sync? = field(0, 16) == SYNC_WORD

      # bsid is 5 bits at the same place in both: 8 and under is AC-3, over 10 is E-AC-3.
      def eac3? = field(40, 5) > 10

      # E-AC-3 header: strmtyp 2, substreamid 3, frmsiz 11, then ... acmod 3, lfeon 1, bsid 5, dialnorm 5.
      def independent? = field(16, 2) != 1
      def size_bits = (field(21, 11) + 1) * 16

      # AC-3 header: sync 16, crc1 16, fscod 2, frmsizecod 6, bsid 5, bsmod 3, acmod 3, then the
      # optional mix levels acmod asks for, lfeon 1, dialnorm 5.
      def dialnorm
        position = eac3? ? 16 + 2 + 3 + 11 + 2 + 2 + 3 + 1 + 5 : ac3_dialnorm_position
        code = field(position, DIALNORM_BITS)
        code.zero? ? UNSET : -code
      end

      private

      def ac3_dialnorm_position
        acmod = field(AC3_ACMOD_AT, 3)
        position = AC3_ACMOD_AT + 3
        position += 2 if acmod.anybits?(1) && acmod != 1 # centre mix level
        position += 2 if acmod.anybits?(4)               # surround mix level
        position += 2 if acmod == 2                      # Dolby Surround mode
        position + 1                                     # lfeon
      end

      def field(offset, length)
        (@bits[@start + offset, length] || '').to_i(2)
      end
    end
  end
end
