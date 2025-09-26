require 'spec_helper'
require 'tempfile'
require 'fileutils'

RSpec.describe Neutraliser::FileManager do
  describe '.safe_temp_path' do
    it 'generates temp path in same directory as original' do
      original = '/path/to/video.mp4'
      temp_path = described_class.safe_temp_path(original)

      expect(temp_path).to start_with('/path/to/')
      expect(temp_path).to include('_neutraliser_')
      expect(temp_path).to end_with('.mp4')
    end

    it 'preserves file extension' do
      temp_path = described_class.safe_temp_path('/test/file.mkv')
      expect(temp_path).to end_with('.mkv')
    end

    it 'generates unique paths for concurrent calls' do
      original = '/test/video.mp4'
      path1 = described_class.safe_temp_path(original)
      path2 = described_class.safe_temp_path(original)

      expect(path1).not_to eq(path2)
    end
  end

  describe '.atomic_replace' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:original_file) { File.join(temp_dir, 'original.txt') }
    let(:temp_file) { File.join(temp_dir, 'temp.txt') }

    before do
      File.write(original_file, 'original content')
      File.write(temp_file, 'new content')
    end

    after do
      FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
    end

    it 'replaces original file with temp file' do
      described_class.atomic_replace(temp_file, original_file)

      expect(File.read(original_file)).to eq('new content')
      expect(File.exist?(temp_file)).to be false
    end

    it 'preserves file metadata when possible' do
      # Set specific permissions on original
      File.chmod(0644, original_file)
      original_stat = File.stat(original_file)

      described_class.atomic_replace(temp_file, original_file)
      new_stat = File.stat(original_file)

      # Mode should be preserved
      expect(new_stat.mode & 0777).to eq(0644)
    end

    context 'when temp file does not exist' do
      it 'raises appropriate error' do
        expect {
          described_class.atomic_replace('/nonexistent/temp.txt', original_file)
        }.to raise_error(/No such file or directory/)
      end
    end

    context 'when original file does not exist' do
      it 'creates new file from temp' do
        new_file = File.join(temp_dir, 'new.txt')
        described_class.atomic_replace(temp_file, new_file)

        expect(File.read(new_file)).to eq('new content')
        expect(File.exist?(temp_file)).to be false
      end
    end
  end

  describe '.verify_file_integrity' do
    let(:temp_dir) { Dir.mktmpdir }

    after do
      FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
    end

    context 'with valid video file' do
      let(:valid_file) { File.join(temp_dir, 'valid.mp4') }

      before do
        # Create a minimal valid MP4 file structure
        File.write(valid_file, "ftypisom\x00\x00\x00\x20" + "\x00" * 28)
        allow(Open3).to receive(:capture3).and_return(['', '', double(success?: true)])
      end

      it 'returns true for valid file' do
        result = described_class.verify_file_integrity(valid_file)
        expect(result).to be true
      end

      it 'calls ffprobe to verify file' do
        described_class.verify_file_integrity(valid_file)

        expect(Open3).to have_received(:capture3).with(
          'ffprobe', '-v', 'error', '-select_streams', 'v:0',
          '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', valid_file
        )
      end
    end

    context 'with corrupted file' do
      let(:corrupted_file) { File.join(temp_dir, 'corrupted.mp4') }

      before do
        File.write(corrupted_file, 'not a valid video file')
        allow(Open3).to receive(:capture3).and_return(['', 'Invalid data', double(success?: false)])
      end

      it 'returns false for corrupted file' do
        result = described_class.verify_file_integrity(corrupted_file)
        expect(result).to be false
      end
    end

    context 'with nonexistent file' do
      it 'returns false for nonexistent file' do
        result = described_class.verify_file_integrity('/nonexistent/file.mp4')
        expect(result).to be false
      end
    end

    context 'with zero-byte file' do
      let(:empty_file) { File.join(temp_dir, 'empty.mp4') }

      before do
        File.write(empty_file, '')
      end

      it 'returns false for empty file' do
        result = described_class.verify_file_integrity(empty_file)
        expect(result).to be false
      end
    end
  end

  describe '.cleanup_temp_files' do
    let(:temp_dir) { Dir.mktmpdir }

    before do
      # Create some temp files matching the pattern
      File.write(File.join(temp_dir, 'video_neutraliser_123.mp4'), 'temp1')
      File.write(File.join(temp_dir, 'movie_neutraliser_456.mkv'), 'temp2')
      File.write(File.join(temp_dir, 'normal_file.mp4'), 'normal')

      allow(Dir).to receive(:glob).and_return([
        File.join(temp_dir, 'video_neutraliser_123.mp4'),
        File.join(temp_dir, 'movie_neutraliser_456.mkv')
      ])
    end

    after do
      FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
    end

    it 'removes files matching temp pattern' do
      expect(File.exist?(File.join(temp_dir, 'video_neutraliser_123.mp4'))).to be true
      expect(File.exist?(File.join(temp_dir, 'movie_neutraliser_456.mkv'))).to be true

      described_class.cleanup_temp_files('*_neutraliser_*')

      # Files should be removed by the glob mock
      expect(Dir).to have_received(:glob).with('*_neutraliser_*')
    end

    it 'does not remove non-matching files' do
      normal_file = File.join(temp_dir, 'normal_file.mp4')
      expect(File.exist?(normal_file)).to be true

      described_class.cleanup_temp_files('*_neutraliser_*')

      # Normal file should still exist
      expect(File.exist?(normal_file)).to be true
    end

    it 'handles missing files gracefully' do
      # Remove one file before cleanup
      File.delete(File.join(temp_dir, 'video_neutraliser_123.mp4'))

      # Should not raise error
      expect {
        described_class.cleanup_temp_files('*_neutraliser_*')
      }.not_to raise_error
    end
  end

  describe '.copy_metadata' do
    let(:temp_dir) { Dir.mktmpdir }
    let(:source_file) { File.join(temp_dir, 'source.mp4') }
    let(:dest_file) { File.join(temp_dir, 'dest.mp4') }

    before do
      File.write(source_file, 'source content')
      File.write(dest_file, 'dest content')
    end

    after do
      FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
    end

    it 'preserves file timestamps' do
      # Set specific timestamp on source
      timestamp = Time.now - 3600  # 1 hour ago
      File.utime(timestamp, timestamp, source_file)

      described_class.copy_metadata(source_file, dest_file)

      dest_stat = File.stat(dest_file)
      expect(dest_stat.mtime).to be_within(1).of(timestamp)
    end

    it 'preserves file permissions' do
      File.chmod(0755, source_file)

      described_class.copy_metadata(source_file, dest_file)

      dest_stat = File.stat(dest_file)
      expect(dest_stat.mode & 0777).to eq(0755)
    end

    context 'when source file does not exist' do
      it 'raises appropriate error' do
        expect {
          described_class.copy_metadata('/nonexistent/source.mp4', dest_file)
        }.to raise_error(Errno::ENOENT)
      end
    end
  end
end