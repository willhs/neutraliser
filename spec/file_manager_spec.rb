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

  describe '.cleanup_temp_files' do
    it 'removes only stale neutraliser temp files' do
      old_temp = File.join(temp_dir, 'movie_neutraliser_old.mp4')
      fresh_temp = File.join(temp_dir, 'movie_neutraliser_fresh.mp4')
      other_file = File.join(temp_dir, 'movie.mp4')

      File.write(old_temp, 'x')
      File.write(fresh_temp, 'x')
      File.write(other_file, 'x')

      old_time = Time.now - 7200
      File.utime(old_time, old_time, old_temp)

      described_class.cleanup_temp_files(File.join(temp_dir, '*'))

      expect(File.exist?(old_temp)).to be(false)
      expect(File.exist?(fresh_temp)).to be(true)
      expect(File.exist?(other_file)).to be(true)
    end
  end

  describe '.verify_file_integrity' do
    let(:video) { File.join(temp_dir, 'video.mp4') }

    before do
      File.write(video, 'content')
    end

    it 'returns true when ffprobe succeeds and duration is present' do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return(["12.3\n", '', status])

      expect(described_class.verify_file_integrity(video)).to be(true)
    end

    it 'returns false when ffprobe fails' do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(['', 'bad', status])

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'returns false for missing files' do
      expect(described_class.verify_file_integrity(File.join(temp_dir, 'missing.mp4'))).to be(false)
    end
  end
end
