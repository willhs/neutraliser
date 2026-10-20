require 'spec_helper'

RSpec.describe Neutraliser::DiskGuard do
  let(:gib) { described_class::GIB }

  def guard(**floors) = described_class.new(**floors).tap { |g| allow(g).to receive(:free_bytes).and_return(free) }

  context 'with no floors' do
    let(:free) { 1 }

    it 'is off' do
      expect(guard.enabled?).to be(false)
      expect(guard.verdict('/m', 10 * gib)).to eq(:ok)
    end
  end

  context 'with 30 GiB free' do
    let(:free) { 30 * gib }

    it 'is fine above both floors' do
      expect(guard(min_free: 20 * gib, abort_free: 10 * gib).verdict('/m', 5 * gib)).to eq(:ok)
    end

    it 'skips a file when free space is under min_free' do
      expect(guard(min_free: 40 * gib).verdict('/m', 5 * gib)).to eq(:skip)
    end

    it 'skips a file bigger than the room left, even above min_free' do
      expect(guard(min_free: 1 * gib).verdict('/m', 31 * gib)).to eq(:skip)
    end

    it 'aborts under abort_free, ahead of skipping' do
      expect(guard(min_free: 40 * gib, abort_free: 31 * gib).verdict('/m', 1)).to eq(:abort)
    end
  end

  it 'reads real free space from df' do
    expect(described_class.new.free_bytes(Dir.tmpdir)).to be_a(Integer).and be_positive
  end

  it 'lets the run carry on when free space cannot be read' do
    guard = described_class.new(abort_free: 1)
    allow(guard).to receive(:free_bytes).and_return(nil)
    expect(guard.verdict('/m', 1)).to eq(:ok)
  end
end
