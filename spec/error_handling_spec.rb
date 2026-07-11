require 'spec_helper'
require 'fileutils'

RSpec.describe 'Error Handling and Edge Cases' do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe Neutraliser::Processor do
    it 'exits with error for missing process path' do
      processor = described_class.new

      expect { processor.process(File.join(temp_dir, 'missing.mp4')) }
        .to output(/does not exist/).to_stdout
        .and raise_error(SystemExit)
    end

    it 'continues after per-file processing errors' do
      processor = described_class.new
      video = File.join(temp_dir, 'movie.mp4')
      File.write(video, 'x')
      movie = instance_double(FFMPEG::Movie, path: video, audio_stream: true)

      allow(FFMPEG::Movie).to receive(:new).and_return(movie)
      allow(processor).to receive(:analyze_loudness_for_path).and_raise(StandardError, 'boom')

      expect { processor.send(:process_file, video) }
        .to output(/Error processing file: boom/).to_stdout
    end
  end

  describe Neutraliser::FFmpegWrapper do
    it 'raises parse error when loudnorm json is missing' do
      status = instance_double(Process::Status, success?: true)
      allow(described_class).to receive(:execute_with_timeout).and_return(['', 'missing', status])

      expect { described_class.measure_loudness('test.mp4') }
        .to raise_error(Neutraliser::FFmpegError, /loudnorm JSON not found/)
    end
  end

  describe Neutraliser::CacheManager do
    it 'deletes corrupt cache files and returns nil' do
      manager = described_class.new(enabled: true)
      video = File.join(temp_dir, 'movie.mp4')
      File.write(video, 'x')

      profile = { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 }
      cache_file = manager.cache_path(video, profile)
      File.write(cache_file, '{invalid json')

      result = manager.load_cached_analysis(video, profile)

      expect(result).to be_nil
      expect(File.exist?(cache_file)).to be(false)
    end
  end

  describe Neutraliser::FileManager do
    it 'returns false when ffprobe invocation raises' do
      video = File.join(temp_dir, 'movie.mp4')
      File.write(video, 'x')

      allow(Open3).to receive(:capture3).and_raise(StandardError, 'ffprobe unavailable')

      expect(described_class.verify_file_integrity(video)).to be(false)
    end
  end

  describe Neutraliser::AudioAnalyser do
    it 'handles missing LUFS fields without crashing' do
      analyser = described_class.new
      profile = { lufs: -20.0 }

      expect { analyser.needs_normalization?({}, profile) }.not_to raise_error
    end
  end
end
