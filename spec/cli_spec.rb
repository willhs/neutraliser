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

      expect do
        described_class.start(['process', '--resume', '/tmp/library'])
      end.to output(/Summary: found=2, queued=1, resumed=1, done=1, skipped=0, failed=0/).to_stdout
    end

    it 'passes --allow-dynamic to Processor initialization' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(
        found: 1, queued: 1, resumed: 0, done: 1, skipped: 0, failed: 0, linear: 0, dynamic: 1,
        manifest_path: '/tmp/manifest', results: []
      )

      expect(Neutraliser::Processor).to receive(:new) do |**kwargs|
        expect(kwargs[:allow_dynamic]).to eq(true)
        processor
      end

      expect do
        described_class.start(['process', '--allow-dynamic', '/tmp/library'])
      end.to output(/linear=0, dynamic=1/).to_stdout
    end

    it 'defaults allow_dynamic to false' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(found: 0, queued: 0, resumed: 0, done: 0, skipped: 0, failed: 0)

      expect(Neutraliser::Processor).to receive(:new) do |**kwargs|
        expect(kwargs[:allow_dynamic]).to eq(false)
        processor
      end

      described_class.start(['process', '/tmp/library'])
    end

    it 'refuses --fast without --allow-dynamic, with a clear message' do
      expect do
        expect { described_class.start(['process', '--fast', '/tmp/library']) }.to raise_error(SystemExit)
      end.to output(/--fast.*--allow-dynamic/m).to_stderr
    end

    it 'accepts --linear-only as a deprecated no-op' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(found: 0, queued: 0, resumed: 0, done: 0, skipped: 0, failed: 0)
      allow(Neutraliser::Processor).to receive(:new).and_return(processor)

      expect { described_class.start(['process', '--linear-only', '/tmp/library']) }
        .to output(/--linear-only is now the default/).to_stderr
    end

    it 'exits non-zero when processing summary contains failures' do
      processor = instance_double(Neutraliser::Processor)
      allow(processor).to receive(:process).and_return(
        found: 1, queued: 1, resumed: 0, done: 0, skipped: 0, failed: 1, manifest_path: '/tmp/manifest', results: []
      )
      allow(Neutraliser::Processor).to receive(:new).and_return(processor)

      expect do
        described_class.start(['process', '/tmp/library'])
      end.to raise_error(SystemExit) do |error|
        expect(error.status).to eq(1)
      end
    end
  end

  describe '.command_known?' do
    # Regression: Thor stores `analyze-plex` under its method name,
    # `analyze_plex`. .start runs before Thor's own hyphen resolution, so the
    # hyphenated form looked unknown and got rewritten to
    # `process analyze-plex` — the exact command the README documents failed
    # with "was called with arguments [...]".
    it 'recognises hyphenated command names' do
      expect(described_class.command_known?('analyze-plex')).to be true
    end

    it 'still recognises underscored and plain command names' do
      expect(described_class.command_known?('analyze_plex')).to be true
      expect(described_class.command_known?('profiles')).to be true
      expect(described_class.command_known?('cache')).to be true
    end

    it 'does not treat an arbitrary path as a command' do
      expect(described_class.command_known?('/tmp/library')).to be false
      expect(described_class.command_known?('movie.mkv')).to be false
    end
  end

  describe 'hyphenated command routing' do
    it 'routes analyze-plex to the analyze_plex command, not process' do
      analyzer = instance_double(Neutraliser::PlexAnalyzer, analyze: nil)
      allow(Neutraliser::PlexAnalyzer).to receive(:new).and_return(analyzer)
      expect(Neutraliser::Processor).not_to receive(:new)

      described_class.start(['analyze-plex', '--token', 'x', '--server-url', 'http://localhost:32400'])
    end
  end
end
