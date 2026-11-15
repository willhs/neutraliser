require 'spec_helper'
require 'fileutils'
require 'stringio'
require_relative 'support/ladder_fixture'

# The levelling ladder run for real: `process --ladder --replace` on one generated clip per rung, the
# output read back with ebur128 (not the loudnorm filter the tool decides with), the stamp read from the
# file, and `report` asked which rung each file took.
RSpec.describe 'Levelling ladder (--ladder) on real files', :real_ffmpeg do
  before(:all) do
    @skip_real = !system('which ffmpeg ffprobe > /dev/null 2>&1')
    next if @skip_real

    @fixtures = Dir.mktmpdir
    @source = %i[narrow peaky wide dts dialogue].to_h { |kind| [kind, LadderFixture.build(kind, File.join(@fixtures, "#{kind}.mkv"))] }
  end
  after(:all) { FileUtils.remove_entry(@fixtures) if @fixtures }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before { skip 'ffmpeg/ffprobe not available on PATH' if @skip_real }

  def copy(kind) = FileUtils.cp(@source.fetch(kind), File.join(@dir, "#{kind}.mkv")).then { File.join(@dir, "#{kind}.mkv") }

  def run_cli(*args)
    out = StringIO.new
    real = [$stdout, $stderr]
    $stdout = $stderr = out
    begin
      Neutraliser::CLI.start(['process', '--replace', *args])
    rescue SystemExit => e
      raise "neutraliser exited #{e.status}:\n#{out.string}" unless e.status.zero?
    end
    out.string
  ensure
    $stdout, $stderr = real
  end

  def stamp_of(path) = Neutraliser::Source.new(path).stamp
  def rung_of(path) = Neutraliser::Report.new(path).rows.first.rung_label
  def levels(path) = LraFixture.measure(path)

  it 'rung 1: levels a file with headroom by constant gain alone, stamped recipe 3' do
    path = copy(:narrow)
    run_cli('--ladder', path)

    expect(stamp_of(path)).to have_attributes(mode: 'linear', recipe: Neutraliser::Recipe::LADDER, profile: 'livingroom',
                                              compression: nil, target_i: nil)
    expect(levels(path)[:i]).to be_within(0.7).of(-20.0)
    expect(rung_of(path)).to eq('1-gain')
  end

  it 'without --ladder: the same file is levelled as before, recipe 2' do
    path = copy(:narrow)
    run_cli(path)

    expect(stamp_of(path)).to have_attributes(mode: 'linear', recipe: Neutraliser::Recipe::CONSTANT_GAIN)
  end

  it 'rung 2: holds the peaks that block the gain with the limiter (ffmpeg 5.1+), else leaves the file alone' do
    path = copy(:peaky)
    out = run_cli('--ladder', path)

    if Neutraliser::FFmpegWrapper.wide_filter_options?
      expect(stamp_of(path)).to have_attributes(mode: 'limited', recipe: 3)
      expect(levels(path)[:peak]).to be <= -1.0
      expect(rung_of(path)).to eq('2-limiter')
    else
      expect(out).to include('without its limiter rung', 'Peak-limited')
      expect(stamp_of(path)).to be_nil
    end
  end

  it 'rung 3: compresses a file whose loudness range is over the limit, then levels it' do
    path = copy(:wide)
    expect(levels(path)[:lra]).to be > 13.5
    run_cli('--ladder', '--tolerance', '0.5', path)

    stamp = stamp_of(path)
    expect(stamp).to have_attributes(mode: 'compressed', recipe: 3)
    expect(levels(path)[:lra]).to be < levels(@source.fetch(:wide))[:lra] - 1.0
    expect(rung_of(path)).to eq('3-compress')
  end

  it 'rung 4: leaves a DTS track alone by default, converts and levels it under --allow-codec-change' do
    path = copy(:dts)
    run_cli('--ladder', path)
    expect(stamp_of(path)).to be_nil

    run_cli('--ladder', '--allow-codec-change', path)
    expect(stamp_of(path)).to have_attributes(mode: 'linear', recipe: 3, source_codec: 'dts')
    expect(Neutraliser::Source.new(path).primary_track[:codec]).not_to eq('dts')
    expect(levels(path)[:i]).to be_within(0.7).of(-20.0)
    expect(rung_of(path)).to eq('1-gain+convert')
  end

  it 'dialogue anchor: puts the centre-channel dialogue at the target and records how' do
    path = copy(:dialogue)
    before_centre = LadderFixture.centre_loudness(path)
    run_cli('--ladder', '--anchor', 'dialogue', '--target-level', '-27', path)

    stamp = stamp_of(path)
    expect(stamp).to have_attributes(profile: 'dialogue-27', recipe: 3, mode: 'linear')
    expect(stamp.dialogue_i).to be_within(1.0).of(before_centre)
    expect(stamp.target_i).to be_within(0.1).of(stamp.measured_i + stamp.gain_db)
    expect(LadderFixture.centre_loudness(path)).to be_within(1.0).of(-27.0)
    expect(run_cli('--ladder', '--anchor', 'dialogue', path)).to include('Already processed, skipping')
  end

  it 'report counts the rungs across a library' do
    narrow = copy(:narrow)
    dts = copy(:dts)
    run_cli('--ladder', narrow)
    run_cli('--ladder', '--allow-codec-change', dts)

    report = Neutraliser::Report.new(@dir)
    expect(report.counts[:rungs]).to eq('1-gain' => 1, '1-gain+convert' => 1)
    expect(report.summary).to include('Rungs: 1-gain=1, 1-gain+convert=1', 'Recipes: 3=2')
    expect(report.to_tsv.lines.first.chomp.split("\t").last).to eq('rung')
  end
end
