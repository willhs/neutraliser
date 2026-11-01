require 'spec_helper'
require 'fileutils'

# The sampling and the guard rails, with stand-in files. The run itself, with
# real clips and a real ffmpeg, is in recipe_and_rate_spec.rb.
RSpec.describe Neutraliser::RateHarness do
  let(:dir) { Dir.mktmpdir }
  let(:tv) { File.join(dir, 'tv') }
  let(:movies) { File.join(dir, 'movies') }
  let(:work) { File.join(dir, 'scratch') }

  after { FileUtils.remove_entry(dir) }

  def touch(root, *names)
    names.each do |name|
      path = File.join(root, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'x')
    end
  end

  def harness(size:, roots: [tv, movies], seed: 1, **options)
    described_class.new(roots: roots, size: size, seed: seed, work_dir: work, **options)
  end

  def split(picks) = picks.map { |pick| File.basename(pick.root) }.tally

  before do
    touch(tv, *(1..10).map { |i| "Show/S01E#{format('%02d', i)}.mkv" })
    touch(movies, 'A (2001)/A.mkv', 'B (2002)/B.mkv')
  end

  it 'gives each root an equal share, so a few films are not drowned by many episodes' do
    expect(split(harness(size: 4).plan)).to eq('tv' => 2, 'movies' => 2)
    expect(split(harness(size: 5).plan).values.sort).to eq([2, 3])
  end

  it 'hands a small root\'s unused share to the others' do
    expect(split(harness(size: 8).plan)).to eq('tv' => 6, 'movies' => 2)
  end

  it 'takes everything when asked for more than there is' do
    expect(harness(size: 50).plan.size).to eq(12)
  end

  it 'repeats for a seed and is a random choice otherwise' do
    expect(harness(size: 4, seed: 3).plan).to eq(harness(size: 4, seed: 3).plan)
    expect((1..8).map { |seed| harness(size: 4, seed: seed).plan.map(&:file) }.uniq.size).to be > 1
  end

  it 'draws only video files, never this tool\'s own copies or temp files' do
    touch(movies, 'A (2001)/A_normalized.mkv', 'A (2001)/notes.txt', 'A (2001)/.A.mkv_neutraliser_0123456789abcdef.mkv')

    expect(harness(size: 50, roots: [movies]).plan.map(&:relative)).to contain_exactly('A (2001)/A.mkv', 'B (2002)/B.mkv')
  end

  it 'writes nothing while planning' do
    before = Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sort
    harness(size: 4).plan

    expect(Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).sort - ['scratch']).to eq(before)
  end

  it 'refuses a work folder inside a root without creating it, even through a symlink' do
    expect { harness(size: 4, work_dir: File.join(tv, 'scratch', 'deeper')) }.to raise_error(described_class::Error, /inside/)
    expect(Dir.exist?(File.join(tv, 'scratch'))).to be false

    link = File.join(dir, 'link')
    File.symlink(movies, link)
    expect { harness(size: 4, work_dir: File.join(link, 'scratch')) }.to raise_error(described_class::Error, /inside/)
    expect(Dir.exist?(File.join(movies, 'scratch'))).to be false
  end

  it 'will not work with nothing to sample' do
    expect { harness(size: 0) }.to raise_error(described_class::Error, /at least 1/)
    expect { harness(size: 1, roots: []) }.to raise_error(described_class::Error, /at least one root/)
    expect { harness(size: 1, roots: [File.join(dir, 'missing')]) }.to raise_error(described_class::Error, /not a directory/)
    expect { harness(size: 1, roots: [File.join(dir, 'empty')].each { |r| FileUtils.mkdir_p(r) }).run }
      .to raise_error(described_class::Error, /No video files/)
  end

  it 'refuses a recipe the processor refuses, before copying anything' do
    expect { harness(size: 1, processor_options: { fast: true }) }.to raise_error(ArgumentError, /--fast/)
  end
end
