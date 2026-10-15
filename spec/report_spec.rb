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
    allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp) do |path|
      stamps.fetch(path.delete_prefix("#{dir}/"))
    end
  end

  after { FileUtils.remove_entry(dir) }

  it 'counts linear, dynamic and untouched files and the profile mix' do
    expect(described_class.new(dir).counts).to eq(
      total: 4, linear: 2, dynamic: 1, untouched: 1, profiles: { 'livingroom' => 2, 'night' => 1 }
    )
  end

  it 'summarises the counts' do
    summary = described_class.new(dir).summary

    expect(summary).to include('Files: 4', 'normalised linear:  2', 'normalised dynamic: 1', 'untouched:          1',
                               'Profiles: livingroom=2, night=1')
  end

  it 'prints one TSV row per file' do
    lines = described_class.new(dir).to_tsv.lines.map(&:chomp)

    expect(lines.first).to start_with("file\tstate\tprofile\tgain_db")
    expect(lines.size).to eq(5)
    expect(lines.find { |l| l.include?('a.mkv') }.split("\t")[1..3]).to eq(%w[linear livingroom 2.5])
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
end
