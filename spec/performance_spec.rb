require 'spec_helper'
require 'fileutils'

RSpec.describe 'Performance and Validation' do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe 'Cache scaling' do
    it 'returns stats for large sidecar sets' do
      500.times do |i|
        File.write(File.join(temp_dir, "movie_#{i}.loudnorm_livingroom.json"), '{}')
      end

      stats = Neutraliser::CacheManager.new(enabled: true).cache_stats(temp_dir)

      expect(stats[:enabled]).to be(true)
      expect(stats[:count]).to eq(500)
      expect(stats[:total_size_mb]).to be >= 0
    end
  end

  describe 'File extension handling' do
    it 'accepts known video extensions and rejects unsupported ones' do
      processor = Neutraliser::Processor.new

      expect(processor.send(:video_file?, 'movie.mp4')).to be(true)
      expect(processor.send(:video_file?, 'show.mkv')).to be(true)
      expect(processor.send(:video_file?, 'notes.txt')).to be(false)
      expect(processor.send(:video_file?, 'archive.zip')).to be(false)
    end
  end
end
