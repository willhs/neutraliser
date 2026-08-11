require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::FileManager do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe '.atomic_replace' do
    it 'replaces target file with source file content' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      described_class.atomic_replace(source, target)

      expect(File.read(target)).to eq('new')
      expect(File.exist?(source)).to be(false)
      expect(File.exist?("#{target}.bak")).to be(false)
    end

    it 'raises when target file does not exist' do
      source = File.join(temp_dir, 'source.mp4')
      File.write(source, 'new')

      expect { described_class.atomic_replace(source, File.join(temp_dir, 'missing.mp4')) }
        .to raise_error(Neutraliser::FileManagerError, /Target file does not exist/)
    end

    it 'raises when source file does not exist' do
      target = File.join(temp_dir, 'target.mp4')
      File.write(target, 'old')

      expect { described_class.atomic_replace(File.join(temp_dir, 'missing.mp4'), target) }
        .to raise_error(Neutraliser::FileManagerError, /Source file does not exist/)
    end

    it 'never leaves target_path missing partway through (single rename, no backup-swap window)' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      seen_missing = false
      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        seen_missing = true unless File.exist?(target)
        original.call(*args)
      end

      described_class.atomic_replace(source, target)

      expect(seen_missing).to be(false)
      expect(File.exist?(target)).to be(true)
    end

    it 'raises FileManagerError and leaves both files untouched on cross-filesystem rename (EXDEV)' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      allow(File).to receive(:rename).with(source, target).and_raise(Errno::EXDEV, 'cross-device link')

      expect { described_class.atomic_replace(source, target) }
        .to raise_error(Neutraliser::FileManagerError, /different filesystems/)

      expect(File.read(target)).to eq('old')
      expect(File.read(source)).to eq('new')
    end

    it 'preserves the original file permission bits' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')
      File.chmod(0o600, target)

      described_class.atomic_replace(source, target)

      expect(File.stat(target).mode & 0o7777).to eq(0o600)
    end
  end

  describe '.atomic_write' do
    it 'writes content that is fully readable back (no partial/truncated state observable)' do
      path = File.join(temp_dir, '.neutraliser')

      described_class.atomic_write(path, '{"a":1}')

      expect(File.read(path)).to eq('{"a":1}')
    end

    it 'never exposes the destination path missing or truncated mid-write' do
      path = File.join(temp_dir, 'cache.json')
      File.write(path, 'original content')

      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        expect(File.read(path)).to eq('original content')
        original.call(*args)
      end

      described_class.atomic_write(path, 'new content')

      expect(File.read(path)).to eq('new content')
    end

    it 'cleans up the temp file and re-raises if the write fails' do
      path = File.join(temp_dir, 'cache.json')
      allow_any_instance_of(File).to receive(:write).and_raise(Errno::ENOSPC, 'no space left on device')

      expect { described_class.atomic_write(path, 'content') }.to raise_error(Errno::ENOSPC)
      expect(Dir.glob(File.join(temp_dir, '*_neutraliser_*'))).to be_empty
    end

    it 'cleans up the temp file when the write is interrupted' do
      path = File.join(temp_dir, 'cache.json')
      allow_any_instance_of(File).to receive(:write).and_raise(Interrupt)

      expect { described_class.atomic_write(path, 'content') }.to raise_error(Interrupt)
      expect(Dir.glob(File.join(temp_dir, '*_neutraliser_*'))).to be_empty
    end

    it 'creates new sidecars with private permissions' do
      path = File.join(temp_dir, 'cache.json')

      described_class.atomic_write(path, 'content')

      expect(File.stat(path).mode & 0o7777).to eq(0o600)
    end
  end

  describe '.atomic_copy' do
    it 'publishes a completed copy and preserves existing destination permissions' do
      source = File.join(temp_dir, 'source.mp4')
      destination = File.join(temp_dir, 'destination.mp4')
      File.write(source, 'new content')
      File.write(destination, 'old content')
      File.chmod(0o600, destination)

      described_class.atomic_copy(source, destination)

      expect(File.read(destination)).to eq('new content')
      expect(File.stat(destination).mode & 0o7777).to eq(0o600)
    end

    it 'leaves an existing destination untouched and cleans up after a partial-copy failure' do
      source = File.join(temp_dir, 'source.mp4')
      destination = File.join(temp_dir, 'destination.mp4')
      File.write(source, 'new content')
      File.write(destination, 'old content')
      allow(IO).to receive(:copy_stream).and_raise(Errno::ENOSPC, 'no space left on device')

      expect { described_class.atomic_copy(source, destination) }.to raise_error(Errno::ENOSPC)

      expect(File.read(destination)).to eq('old content')
      expect(Dir.glob(File.join(temp_dir, '*_neutraliser_*'))).to be_empty
    end
  end

  describe '.safe_temp_path' do
    it 'creates a neutraliser temp filename in the same directory' do
      original = File.join(temp_dir, 'movie.mkv')
      temp_path = described_class.safe_temp_path(original)

      expect(File.dirname(temp_path)).to eq(temp_dir)
      expect(File.basename(temp_path)).to match(/^movie_neutraliser_[0-9a-f]{16}\.mkv$/)
    end
  end

  describe '.verify_file_integrity' do
    let(:video) { File.join(temp_dir, 'video.mp4') }

    before do
      File.write(video, 'content')
    end

    it 'returns true when the probe succeeds and duration is present' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_duration).with(video).and_return(12.3)

      expect(described_class.verify_file_integrity(video)).to be(true)
    end

    it 'returns false when the probe reports no usable duration (corrupt output)' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_duration).with(video).and_return(nil)

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'returns false when the probe times out (treated as unverifiable output, not an environment problem)' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_duration).with(video)
                                                                   .and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'raises FileManagerError, distinct from a corrupt-output false, when ffprobe is missing' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_duration).with(video)
                                                                   .and_raise(Errno::ENOENT, 'ffprobe')

      expect { described_class.verify_file_integrity(video) }
        .to raise_error(Neutraliser::FileManagerError, /ffprobe not found/)
    end

    it 'goes through FFmpegWrapper.probe_duration rather than an unbounded direct ffprobe call' do
      expect(Neutraliser::FFmpegWrapper).to receive(:probe_duration).with(video).and_return(1.0)

      described_class.verify_file_integrity(video)
    end

    it 'returns false for missing files' do
      expect(described_class.verify_file_integrity(File.join(temp_dir, 'missing.mp4'))).to be(false)
    end
  end
end
