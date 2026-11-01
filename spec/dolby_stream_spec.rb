# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Neutraliser::DolbyStream do
  # A frame header as bits, padded out to bytes: only the fields the parser reads.
  def bits_to_bytes(bits) = [bits.ljust((bits.length + 7) / 8 * 8, '0')].pack('B*')

  def field(value, width) = value.to_s(2).rjust(width, '0')

  # sync, crc1, fscod 0 + frmsizecod 8, bsid, bsmod, acmod, then the mix-level fields acmod calls for, lfeon, dialnorm code
  def ac3_frame(acmod:, code:, bsid: 8)
    mix = (acmod.anybits?(1) && acmod != 1 ? '00' : '') + (acmod.anybits?(4) ? '00' : '') + (acmod == 2 ? '00' : '')
    bits_to_bytes("0000101101110111#{'0' * 16}00001000#{field(bsid, 5)}000#{field(acmod, 3)}#{mix}1#{field(code, 5)}#{'0' * 64}")
  end

  # sync, strmtyp, substreamid, frmsiz (words - 1), fscod, numblkscod, acmod, lfeon, bsid 16, dialnorm code
  def eac3_frame(code:, strmtyp: 0, words: 10)
    header = "0000101101110111#{field(strmtyp, 2)}000#{field(words - 1, 11)}0011#{field(7, 3)}1#{field(16, 5)}#{field(code, 5)}"
    bits_to_bytes(header).ljust(words * 2, "\0".b)
  end

  describe '.dialnorm' do
    it 'reads an AC-3 frame whatever mix-level fields its channel mode carries' do
      [1, 2, 3, 4, 7].each do |acmod|
        expect(described_class.dialnorm(ac3_frame(acmod: acmod, code: 24))).to eq(-24), "acmod #{acmod}"
      end
    end

    it 'reads an E-AC-3 frame, skipping dependent substreams that come first' do
      stream = eac3_frame(code: 9, strmtyp: 1) + eac3_frame(code: 27, strmtyp: 0)

      expect(described_class.dialnorm(stream)).to eq(-27)
    end

    it 'treats the reserved code 0 as 31, as decoders do' do
      expect(described_class.dialnorm(ac3_frame(acmod: 2, code: 0))).to eq(-31)
    end

    it 'is nil for bytes that are not an AC-3 or E-AC-3 stream, or have no independent frame' do
      expect(described_class.dialnorm('')).to be_nil
      expect(described_class.dialnorm("ID3\x04\x00\x00\x00\x00".b)).to be_nil
      expect(described_class.dialnorm(eac3_frame(code: 9, strmtyp: 1))).to be_nil
    end

    it 'reads what the real encoders write', :real_ffmpeg do
      skip 'ffmpeg not available on PATH' unless system('which ffmpeg > /dev/null 2>&1')

      Dir.mktmpdir do |dir|
        %w[ac3 eac3].product(%w[mono stereo 5.1], [-24, -7, -31, -1]).each do |codec, layout, dialnorm|
          path = File.join(dir, "t.#{codec}")
          system('ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', "sine=d=1,aformat=channel_layouts=#{layout}",
                 '-c:a', codec, '-dialnorm', dialnorm.to_s, '-f', codec, path, exception: true)

          expect(described_class.dialnorm(File.binread(path))).to eq(dialnorm), "#{codec} #{layout}"
        end
      end
    end
  end
end
