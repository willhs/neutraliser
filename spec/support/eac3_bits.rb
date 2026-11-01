# frozen_string_literal: true

require_relative 'ac3_crc'

# E-AC-3 bit editing, which the spec's Ac3Bits doesn't do, for two fixtures ffmpeg's encoder can't write: stream DRC
# and the extension flag that makes a decoder report Dolby Atmos. No audio is touched. Only frames as ffmpeg's own
# encoder writes them (one independent substream, six blocks) are understood, which is all this needs. Encode with
# -channel_coupling 0.
#
# Header layout follows ff_eac3_output_frame_header in libavcodec/eac3enc.c.
module Eac3Bits
  FULL_CHANNELS = [2, 1, 2, 3, 3, 4, 4, 5].freeze # by acmod, not counting LFE

  module_function

  def frames(data)
    offset = 0
    list = []
    while offset + 6 < data.bytesize
      raise "no sync at #{offset}" unless data.byteslice(offset, 2) == "\x0B\x77".b

      words = (((data.getbyte(offset + 2) & 0x07) << 8) | data.getbyte(offset + 3)) + 1
      list << [offset, words * 2]
      offset += words * 2
    end
    list
  end

  # Returns [position of addbsie, position of block 0's first dynrnge flag] for a frame's bits.
  def positions(bits)
    pos = 16 + 2 + 3 + 11
    read = lambda do |n|
      value = bits[pos, n].to_i(2)
      pos += n
      value
    end
    fscod = read.call(2)
    raise 'six-block 48 kHz frames only' unless fscod.zero? && read.call(2) == 3

    acmod = read.call(3)
    lfeon = read.call(1)
    read.call(5) # bsid
    read.call(5) # dialnorm
    read.call(8) if read.call(1) == 1 # compr
    raise 'mixing metadata not handled' unless read.call(1).zero?
    raise 'info metadata not handled' unless read.call(1).zero?

    addbsie = pos
    raise 'frame already has additional bit stream info' unless read.call(1).zero?

    expstre = read.call(1) # exponent strategy syntax: 1 = per channel per block, 0 = per frame
    read.call(1) # ahte
    read.call(2) # snroffststr
    read.call(1) # transproce
    read.call(1) # blkswe
    read.call(1) # dithflage
    read.call(1) # bamode
    read.call(1) # frmfgaincode
    read.call(1) # dbaflde
    read.call(1) # skipflde
    read.call(1) # spxattene
    if acmod > 1 # coupling strategy flags: all off with -channel_coupling 0
      raise 'encode with -channel_coupling 0' unless read.call(1).zero?

      5.times { raise 'encode with -channel_coupling 0' unless read.call(1).zero? }
    end
    full = FULL_CHANNELS[acmod]
    read.call(expstre == 1 ? full * 6 * 2 : full * 5)
    read.call(6) if lfeon == 1 # LFE exponent strategy per block
    read.call(5 * full) # converter exponent strategy
    read.call(6) # coarse SNR offset
    read.call(4) # fine SNR offset
    read.call(1) # block start info
    [addbsie, pos]
  end

  # Inserts `extra` bits after `position`, setting the flag at `position`, and grows the frame by enough whole words
  # to hold them (zero padding, which decoders don't read), then refreshes the CRC.
  def insert(frame, position, extra)
    grow = (extra.length + 15) / 16
    words = (frame.bytesize / 2) + grow
    bits = frame.unpack1('B*')
    body = bits[0, bits.length - 16] # the CRC is recomputed
    body = "#{body[0, position]}1#{extra}#{body[(position + 1)..]}"
    body = body.ljust((words - 1) * 16, '0')[0, (words - 1) * 16]
    body[21, 11] = format('%011b', words - 1)
    out = [body].pack('B*')
    out + [Ac3Crc.crc16(out.byteslice(2, out.bytesize - 2))].pack('n')
  end

  # dynrng in block 0 of each frame (later blocks reuse it): the 8-bit code the block returns for the frame's
  # index, for every full-bandwidth pass (one flag per programme: dual mono is not handled).
  def add_dynrng(data)
    frames(data).each_with_index.map do |(offset, size), index|
      frame = data.byteslice(offset, size).b
      _, dyn = positions(frame.unpack1('B*'))
      insert(frame, dyn, format('%08b', yield(index)))
    end.join.b
  end

  # The extension flag: addbsil 1 (two bytes), first byte's low bit set, then the object-complexity byte.
  # FFmpeg 7.1's decoder reports such a stream as "Dolby Digital Plus + Dolby Atmos".
  def add_atmos_flag(data)
    frames(data).map do |offset, size|
      frame = data.byteslice(offset, size).b
      add, = positions(frame.unpack1('B*'))
      insert(frame, add, "#{format('%06b', 1)}#{format('%08b', 1)}#{format('%08b', 16)}")
    end.join.b
  end
end
