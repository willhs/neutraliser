require 'spec_helper'

RSpec.describe Neutraliser::AudioLayout do
  def layout(tracks, keep_original: false)
    described_class.for(ProbeFixture.source('in.mkv', audio: tracks), keep_original: keep_original)
  end

  def roles(layout) = layout.outputs.map { |o| [o.index, o.role, o.source_index] }

  let(:english) { ProbeFixture.audio(language: 'eng', title: 'English', default: true) }
  let(:french) { ProbeFixture.audio(language: 'fre', title: 'French') }
  let(:commentary) { ProbeFixture.audio(title: 'Commentary') }

  it 'keeps every track where it was and replaces the primary in place' do
    layout = layout([commentary, english, french])

    expect(roles(layout)).to eq([[0, :copied, 0], [1, :normalised, 1], [2, :copied, 2]])
    expect(layout.size).to eq(3)
    expect(layout.normalised.index).to eq(1)
    expect(layout.kept_original).to be_nil
  end

  it 'puts the kept original right after the normalised track and moves later tracks up' do
    layout = layout([english, french], keep_original: true)

    expect(roles(layout)).to eq([[0, :normalised, 0], [1, :kept_original, 0], [2, :copied, 1]])
    expect(layout.size).to eq(3)
    expect(layout.kept_original.index).to eq(1)
  end

  it 'adds no second kept original when an earlier run left one (by title, or by handler name for MP4)' do
    titled = ProbeFixture.audio(title: "English #{described_class::ORIGINAL_TITLE_SUFFIX}")
    handled = ProbeFixture.audio(handler_name: described_class::ORIGINAL_TITLE_SUFFIX)

    [titled, handled].each do |kept|
      layout = layout([english, kept, french], keep_original: true)
      expect(layout.size).to eq(3)
      expect(layout.kept_original).to be_nil
    end
  end

  describe 'dispositions' do
    it 'hands back the flags the filtered primary would lose, default first' do
      track = ProbeFixture.audio(default: true, dispositions: %w[forced hearing_impaired])

      expect(layout([track]).normalised.dispositions).to eq(%w[default forced hearing_impaired])
    end

    it 'leaves a plain non-default primary alone' do
      expect(layout([french, commentary]).normalised.dispositions).to be_nil
    end

    it 'makes the normalised track the default when a kept original sits beside it, and clears the copy' do
      layout = layout([french], keep_original: true)

      expect(layout.normalised.dispositions).to eq(['default'])
      expect(layout.kept_original.dispositions).to eq([])
    end

    it 'does not touch the dispositions of stream-copied tracks' do
      expect(layout([english, french]).outputs.last.dispositions).to be_nil
    end
  end

  it 'has no normalised track for a file without audio' do
    layout = layout([])

    expect(layout.size).to eq(0)
    expect(layout.normalised).to be_nil
  end

  describe '.original_title' do
    it 'appends the suffix to the title, or stands alone for an untitled track' do
      expect(described_class.original_title(title: 'English 5.1')).to eq('English 5.1 (original, not normalised)')
      expect(described_class.original_title(title: nil)).to eq('(original, not normalised)')
      expect(described_class.original_title(title: '')).to eq('(original, not normalised)')
    end
  end
end
