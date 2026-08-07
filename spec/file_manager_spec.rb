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
