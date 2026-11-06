require 'spec_helper'

RSpec.describe Neutraliser::Mode do
  it 'spells a mode one way for the stamp and one way for the manifest and log, both from the same value' do
    expect(described_class::LINEAR.to_s).to eq('linear')
    expect(described_class::LINEAR.label).to eq('Linear')
    expect(described_class::COMPRESSED.label).to eq('Compressed')
  end

  it 'reads a mode back from either spelling' do
    expect(described_class.parse('Linear')).to eq(described_class::LINEAR)
    expect(described_class.parse('dynamic')).to eq(described_class::DYNAMIC)
    expect(described_class.parse(' LIMITED ')).to eq(described_class::LIMITED)
  end

  it 'reads text that names no mode as none' do
    expect(described_class.parse('wobbly')).to be_nil
    expect(described_class.parse(nil)).to be_nil
  end

  it 'is the same set of values the stamp predicates ask about' do
    described_class::ALL.each do |mode|
      stamp = Neutraliser::Stamp.new(version: '1', profile: 'p', recipe: 1, mode: mode.to_s, gain_db: nil, source_codec: nil,
                                     source_bitrate: nil, measured_i: nil, measured_tp: nil, measured_lra: nil, date: nil)
      expect([stamp.linear?, stamp.limited?, stamp.compressed?, stamp.dynamic?].count(true)).to eq(mode == described_class::UNKNOWN ? 0 : 1)
    end
  end
end
