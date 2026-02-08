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

  describe 'Parallel processor' do
    it 'processes all files through worker processors' do
      files = %w[a.mp4 b.mp4 c.mp4].map { |name| File.join(temp_dir, name) }
      files.each { |f| File.write(f, 'x') }

      worker = instance_double(Neutraliser::Processor)
      allow(worker).to receive(:process_one).and_return(
        { status: :done, reason: :normalized, message: nil, file: 'ignored' }
      )
      allow(Neutraliser::Processor).to receive(:new).and_return(worker)

      parallel = Neutraliser::ParallelProcessor.new(max_threads: 2)
      result = parallel.process_files_parallel(files, {
        replace: false,
        profile: Neutraliser::Profiles.get_profile('livingroom'),
        tolerance: 1.0,
        cache: true,
        dry_run: true,
        fast_verify: true,
        resume: false
      })
      parallel.shutdown

      expect(result[:done]).to eq(3)
      expect(result[:failed]).to eq(0)
      expect(worker).to have_received(:process_one).exactly(3).times
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
