# frozen_string_literal: true

# The checksums of an AC-3 frame, for Ac3Bits: crc1 covers the first five eighths of the frame and crc2 the rest.
# Ported from dolby_bits.py in the research spike.
module Ac3Crc
  CRC_TABLE = Array.new(256) do |byte|
    (0...8).reduce(byte << 8) { |crc, _| crc.anybits?(0x8000) ? ((crc << 1) ^ 0x8005) & 0xFFFF : (crc << 1) & 0xFFFF }
  end.freeze

  module_function

  def crc16(bytes, crc = 0)
    bytes.each_byte { |byte| crc = ((crc << 8) & 0xFFFF) ^ CRC_TABLE[(crc >> 8) ^ byte] }
    crc
  end

  def five_eighths(size) = ((size >> 2) + (size >> 4)) << 1

  def fix_crcs(frame)
    size = frame.bytesize
    size58 = five_eighths(size)
    frame = frame.dup
    frame[2, 2] = [solve_crc1(size58, crc16(frame.byteslice(4, size58 - 4)))].pack('n')
    frame[size - 2, 2] = [crc16(frame.byteslice(size58, size - 2 - size58))].pack('n')
    frame
  end

  # The crc1 field value that makes crc16(frame[2...size58]) zero. crc1 sits at the start of what it protects,
  # so it can't be computed by running the CRC forward: the CRC is linear over GF(2), so solve for it with an
  # inverted 16x16 matrix per frame size.
  def solve_crc1(size58, target)
    @crc1_inverse ||= {}
    inverse = (@crc1_inverse[size58] ||= invert_crc_matrix(size58))
    (0...16).sum { |row| ((inverse[row] & target).digits(2).sum & 1) << row }
  end

  def invert_crc_matrix(size58)
    zeros = "\0".b * (size58 - 4)
    columns = Array.new(16) { |bit| crc16(zeros, crc16([1 << bit].pack('n'))) }
    rows = Array.new(16) do |row|
      Array.new(16) { |col| (columns[col] >> row) & 1 } + Array.new(16) { |j| row == j ? 1 : 0 }
    end
    16.times do |pivot|
      lead = (pivot...16).find { |r| rows[r][pivot] == 1 }
      rows[pivot], rows[lead] = rows[lead], rows[pivot]
      16.times do |r|
        rows[r] = rows[r].zip(rows[pivot]).map { |a, b| a ^ b } if r != pivot && rows[r][pivot] == 1
      end
    end
    Array.new(16) { |r| (0...16).sum { |c| rows[r][16 + c] << c } }
  end
end
