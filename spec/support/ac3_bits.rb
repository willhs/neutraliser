# frozen_string_literal: true

require_relative 'ac3_crc'

# AC-3 bitstream editing for the DRC fixture: no audio is touched. A Ruby port of the AC-3 half of
# docs/research/0002-streaming-loudness-and-dialogue/spike/dolby_bits.py; 48 kHz only.
module Ac3Bits
  WORDS_48K = [64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320,
               384, 384, 448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280].freeze
  FULL_CHANNELS = [2, 1, 2, 3, 3, 4, 4, 5].freeze # by acmod, not counting LFE

  module_function

  # [offset, size] of each frame.
  def frames(data)
    offset = 0
    list = []
    while offset + 6 < data.bytesize
      raise "no sync at #{offset}" unless data.byteslice(offset, 2) == "\x0B\x77".b
      raise 'fixtures are 48 kHz AC-3 only' unless data.getbyte(offset + 4) >> 6 == 0 && (data.getbyte(offset + 5) >> 3) <= 10

      size = WORDS_48K.fetch(data.getbyte(offset + 4) & 0x3F) * 2
      list << [offset, size]
      offset += size
    end
    list
  end

  # Position of block 0's dynrnge flag: header fields up to and including the block-switch / dither flags.
  def dynrng_flag_position(frame)
    bits = frame.unpack1('B*')
    pos = 32 + 8 + 5 + 3
    read = lambda do |n|
      value = bits[pos, n].to_i(2)
      pos += n
      value
    end
    acmod = read.call(3)
    read.call(2) if acmod.anybits?(1) && acmod != 1
    read.call(2) if acmod.anybits?(4)
    read.call(2) if acmod == 2
    read.call(1)              # lfeon
    read.call(5)              # dialnorm
    read.call(8) if read.call(1) == 1 # compr
    read.call(8) if read.call(1) == 1 # langcod
    read.call(7) if read.call(1) == 1 # mixlevel, roomtyp
    skip_second_mono_channel(read) if acmod.zero?
    read.call(2) # copyrightb, origbs
    2.times { read.call(14) if read.call(1) == 1 } # timecod1e/2e, or xbsi1e/2e
    read.call((read.call(6) + 1) * 8) if read.call(1) == 1 # addbsi
    read.call(FULL_CHANNELS[acmod] * 2) # blksw, dithflag
    pos
  end

  def skip_second_mono_channel(read)
    read.call(5) # dialnorm2
    read.call(8) if read.call(1) == 1 # compr2
    read.call(8) if read.call(1) == 1 # langcod2
    read.call(7) if read.call(1) == 1 # mixlevel2, roomtyp2
  end

  def has_dynrng?(frame) = frame.unpack1('B*')[dynrng_flag_position(frame)] == '1'

  # Gives each frame a dynrng word in block 0 (later blocks reuse it): the 8-bit code the block returns for
  # that frame's index, or none for nil. Every frame moves up one bitrate class so there is room for the extra
  # bits, and the new space is zero padding, which decoders don't read.
  def add_dynrng(data)
    frames(data).each_with_index.map do |(offset, size), index|
      frame = data.byteslice(offset, size).b
      code = yield(index)
      cod = frame.getbyte(4) & 0x3F
      new_size = WORDS_48K.fetch(cod + 2) * 2
      frame.setbyte(4, (frame.getbyte(4) & 0xC0) | (cod + 2))
      body = frame.byteslice(0, size - 3) + ("\0".b * (new_size - (size - 3))) # the old crcrsv byte goes with the old crc2
      body = insert_dynrng(body, code) if code
      Ac3Crc.fix_crcs(body)
    end.join.b
  end

  def insert_dynrng(body, code)
    flag_pos = dynrng_flag_position(body)
    total_bits = body.bytesize * 8
    value = body.unpack1('H*').to_i(16)
    tail_bits = total_bits - flag_pos - 1
    tail = value & ((1 << tail_bits) - 1) # everything after the old (clear) flag
    head = ((((value >> (total_bits - flag_pos)) << 1) | 1) << 8) | code
    [((head << (tail_bits - 8)) | (tail >> 8)).to_s(16).rjust(body.bytesize * 2, '0')].pack('H*')
  end
end
