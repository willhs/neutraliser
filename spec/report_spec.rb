require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::Report do
  let(:dir) { Dir.mktmpdir }
  let(:stamps) do
    {
      'a.mkv' => stamp('livingroom', 'linear', 2.5),
      'b.mp4' => stamp('night', 'dynamic', nil),
      'c.mkv' => nil,
      'sub/d.mkv' => stamp('livingroom', 'linear', -1.0)
    }
  end

  def stamp(profile, mode, gain)
    Neutraliser::Stamp.now(profile: profile, mode: mode, gain_db: gain, source_codec: 'aac', source_bitrate: nil,
                           measured_i: -24.0, measured_tp: -3.0, measured_lra: 6.0)
  end

  before do
    stamps.each_key do |name|
      FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
      File.write(File.join(dir, name), 'x')
    end
    File.write(File.join(dir, 'notes.txt'), 'not a video')
    stub_stamps { |path| stamps.fetch(path.delete_prefix("#{dir}/")) }
  end

  after { FileUtils.remove_entry(dir) }

  it 'counts linear, dynamic and untouched files and the profile mix' do
    expect(described_class.new(dir).counts).to eq(
      total: 4, linear: 2, limited: 0, compressed: 0, dynamic: 1, untouched: 1,
      profiles: { 'livingroom' => 2, 'night' => 1 }, recipes: { Neutraliser::Recipe::CURRENT.to_s => 3 }, dialnorms: {}, left: {}
    )
  end

  it 'shows the dialnorm carried over, when any file has one' do
    expect(described_class.new(dir).summary).not_to include('Dialnorm')

    stub_stamps { |path| stamps.fetch(path.delete_prefix("#{dir}/"))&.with(source_dialnorm: -24) }
    report = described_class.new(dir)

    expect(report.counts[:dialnorms]).to eq(-24 => 3)
    expect(report.summary).to include('Dialnorm carried over (dB): -24=3')
    expect(report.to_tsv.lines.first.split("\t")).to include('source_dialnorm')
  end

  it 'summarises the counts' do
    summary = described_class.new(dir).summary

    expect(summary).to include('Files: 4', 'normalised linear:  2', 'normalised dynamic: 1', 'untouched:          1',
                               'Profiles: livingroom=2, night=1')
    expect(summary).not_to include('compressed')
  end

  it 'prints one TSV row per file' do
    lines = described_class.new(dir).to_tsv.lines.map(&:chomp)

    expect(lines.first).to start_with("file\tstate\tprofile\trecipe\tgain_db")
    expect(lines.size).to eq(5)
    expect(lines.find { |l| l.include?('a.mkv') }.split("\t")[1..3]).to eq(['linear', 'livingroom', Neutraliser::Recipe::CURRENT.to_s])
    expect(lines.find { |l| l.include?('c.mkv') }.split("\t")[1]).to eq('untouched')
  end

  it 'emits JSON with the summary and per-file stamps' do
    data = JSON.parse(described_class.new(dir).to_json)

    expect(data['summary']).to include('total' => 4, 'dynamic' => 1)
    b = data['files'].find { |f| f['file'].end_with?('b.mp4') }
    expect(b).to include('state' => 'dynamic')
    expect(b['stamp']).to include('profile' => 'night', 'gain_db' => nil)
  end

  it 'runs through the CLI' do
    expect { Neutraliser::CLI.start(['report', dir]) }.to output(/normalised dynamic: 1/).to_stdout
    expect { Neutraliser::CLI.start(['report', dir, '--format', 'tsv']) }
      .to output(/b\.mp4\tdynamic\tnight/).to_stdout.and output(/Files: 4/).to_stderr
  end

  describe 'left-alone files and the remote-free rate' do
    let(:peaky) do
      Neutraliser::LeftRecord.new(reason: 'peak_limited', profile: 'livingroom', recipe: 1, message: 'peak ceiling allows -1.8 dB',
                                  measured_i: -30.0, measured_tp: -0.5, measured_lra: 4.0)
    end

    before do
      Neutraliser::SkipDecider.new(dir).mark_left(File.join(dir, 'c.mkv'), peaky)
      stamps['d.mkv'] = Neutraliser::Stamp.now(profile: 'livingroom', recipe: nil, mode: 'linear', gain_db: 3.0,
                                               source_codec: 'aac', source_bitrate: nil, measured_i: -23.0,
                                               measured_tp: -6.0, measured_lra: 5.0)
      File.write(File.join(dir, 'd.mkv'), 'x')
    end

    it 'says why an untouched file was left alone, with its measured levels' do
      report = described_class.new(dir)
      c = report.rows.find { |row| row.file.end_with?('c.mkv') }

      expect(c).to have_attributes(state: 'untouched', left: peaky)
      expect(report.counts[:left]).to eq('peak_limited' => 1)
      expect(report.summary).to include('left alone: peak_limited=1')
      row = report.to_tsv.lines.find { |l| l.include?('c.mkv') }.chomp.split("\t")
      header = report.to_tsv.lines.first.chomp.split("\t")
      expect(row.zip(header).to_h { |value, name| [name, value] })
        .to include('left_reason' => 'peak_limited', 'measured_i' => '-30.0', 'measured_lra' => '4.0')
    end

    it 'counts recipes, with files from before recipes as unversioned' do
      expect(described_class.new(dir).counts[:recipes]).to eq(Neutraliser::Recipe::CURRENT.to_s => 3, 'unversioned' => 1)
      expect(described_class.new(dir).summary).to include("Recipes: #{Neutraliser::Recipe::CURRENT}=3, unversioned=1")
    end

    it 'judges what it can from the records and counts the rest apart' do
      rate = described_class.new(dir).rate

      # a: -24+2.5=-21.5 ok; b: dynamic, night -16 ok; c: -30 off; d: -20 ok; sub/d: -24-1=-25 off
      expect(rate.to_h).to include(judged: 5, remote_free: 3, off_level: 2, not_judged: 0, measured: 0)
    end

    it 'measures every file instead when asked, against the profile for files with no record' do
      measure = lambda do |path, **|
        level = path.end_with?('c.mkv') ? -21.0 : -35.0
        Neutraliser::Measurement.new(input_i: level, input_tp: -3.0, input_lra: 5.0, input_thresh: -45.0, target_offset: 0.0)
      end
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness, &measure)

      report = described_class.new(dir, measure: true)

      expect(report.rate.to_h).to include(judged: 5, measured: 5, remote_free: 1)
      c = report.rows.find { |row| row.file.end_with?('c.mkv') }
      expect(report.final_levels_for(c)).to have_attributes(target: -20.0, basis: :measured)
      expect(Neutraliser::FFmpegWrapper).to have_received(:measure_loudness)
        .with(c.file, hash_including(target_i: -20.0)).once
    end

    it 'skips a file it cannot measure and says how many it did not judge' do
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_raise(Neutraliser::FFmpegError, 'boom')

      expect(described_class.new(dir, measure: true).rate.to_h).to include(judged: 0, not_judged: 5)
    end

    it 'takes the target for untouched files from --profile and the limits from the flags' do
      loose = described_class.new(dir, within_lu: 20.0, lra_limit: 100.0)
      tight = described_class.new(dir, within_lu: 0.1)

      expect(loose.rate.remote_free).to eq(5)
      expect(tight.rate.remote_free).to eq(2) # only the two landing exactly on target
    end

    it 'prints the rate through the CLI, in JSON too' do
      expect { Neutraliser::CLI.start(['report', dir]) }.to output(/Remote-free rate: 60.0% \(3 of 5/).to_stdout
      expect { Neutraliser::CLI.start(['report', dir, '--format', 'json']) }
        .to output(/"remote_free_rate": \{\s+"rate": 0.6/).to_stdout
    end
  end

  it 'counts compressed files and shows them only when there are some' do
    compressed = Neutraliser::Stamp.now(profile: 'livingroom', mode: 'compressed', gain_db: 6.0, source_codec: 'ac3',
                                        source_bitrate: nil, measured_i: -22.0, measured_tp: -8.0, measured_lra: 16.0,
                                        compression: 'gentle', centre_boost_db: nil, lra_after: 10.0)
    stub_stamp(compressed)

    report = described_class.new(File.join(dir, 'a.mkv'))

    expect(report.counts).to include(total: 1, compressed: 1, linear: 0)
    expect(report.summary).to include('normalised compressed: 1')
    expect(report.to_tsv).to include("gentle\t\t10.0")
  end
end
