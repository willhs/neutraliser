require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::CacheCommands do
  describe '.start clean' do
    let(:temp_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir) }

    it 'removes legacy .neutralised_<profile> marker sidecars alongside cache cleanup' do
      video = File.join(temp_dir, 'movie.mp4')
      File.write(video, 'x')
      legacy_marker = File.join(temp_dir, '.movie.neutralised_livingroom')
      File.write(legacy_marker, '{}')

      expect { described_class.start(['clean', temp_dir]) }
        .to output(/Removed 1 legacy '\.neutralised_<profile>' marker file\(s\)/).to_stdout

      expect(File.exist?(legacy_marker)).to be false
    end

    it 'does not print a removal line when there are no legacy markers' do
      video = File.join(temp_dir, 'movie.mp4')
      File.write(video, 'x')

      expect { described_class.start(['clean', temp_dir]) }
        .not_to output(/legacy/).to_stdout
    end
  end
end

RSpec.describe Neutraliser::CLI do
  describe '.start process command' do
    it 'passes --resume to Processor initialization' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(
        found: 2, queued: 1, resumed: 1, done: 1, skipped: 0, failed: 0, manifest_path: '/tmp/manifest', results: []
      )

      expect(Neutraliser::Processor).to receive(:new) do |**kwargs|
        expect(kwargs[:resume]).to eq(true)
        processor
      end

      expect {
        described_class.start(['process', '--resume', '/tmp/library'])
      }.to output(/Summary: found=2, queued=1, resumed=1, done=1, skipped=0, failed=0/).to_stdout
    end

    it 'passes --linear-only to Processor initialization' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(
        found: 1, queued: 1, resumed: 0, done: 1, skipped: 0, failed: 0, manifest_path: '/tmp/manifest', results: []
      )

      expect(Neutraliser::Processor).to receive(:new) do |**kwargs|
        expect(kwargs[:linear_only]).to eq(true)
        processor
      end

      described_class.start(['process', '--linear-only', '/tmp/library'])
    end

    it 'exits non-zero when processing summary contains failures' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(
        found: 1, queued: 1, resumed: 0, done: 0, skipped: 0, failed: 1, manifest_path: '/tmp/manifest', results: []
      )
      allow(Neutraliser::Processor).to receive(:new).and_return(processor)

      expect {
        described_class.start(['process', '/tmp/library'])
      }.to raise_error(SystemExit) do |error|
        expect(error.status).to eq(1)
      end
    end
  end
end
