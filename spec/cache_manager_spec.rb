require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::CacheManager do
  let(:temp_dir) { Dir.mktmpdir }
  let(:video_file) { File.join(temp_dir, 'movie.mp4') }
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:measurement) do
    Neutraliser::Measurement.from_loudnorm_json(
      'input_i' => '-18.5',
      'input_tp' => '-2.1',
      'input_lra' => '8.3',
      'input_thresh' => '-28.9',
      'target_offset' => '1.5'
    )
  end

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  before do
    File.write(video_file, 'video')
  end

  describe '#save_analysis and #load_cached_analysis' do
    it 'round-trips loudnorm analysis data' do
      manager = described_class.new(enabled: true)

      manager.save_analysis(video_file, profile, measurement)
      loaded = manager.load_cached_analysis(video_file, profile)

      expect(loaded).to eq(measurement)
    end

    it 'invalidates cache when version mismatches' do
      manager = described_class.new(enabled: true)
      cache_file = manager.cache_path(video_file, profile)
      File.write(cache_file, JSON.pretty_generate({ 'cache_version' => '0.0' }))

      loaded = manager.load_cached_analysis(video_file, profile)

      expect(loaded).to be_nil
      expect(File.exist?(cache_file)).to be(false)
    end

    it 'invalidates cache when source video is newer than cache' do
      manager = described_class.new(enabled: true)
      manager.save_analysis(video_file, profile, measurement)
      cache_file = manager.cache_path(video_file, profile)

      # Bump source file mtime to be newer than cache
      future = File.mtime(cache_file) + 10
      File.utime(future, future, video_file)

      loaded = manager.load_cached_analysis(video_file, profile)

      expect(loaded).to be_nil
      expect(File.exist?(cache_file)).to be(false)
    end
  end

  describe '#cleanup_stale_cache' do
    it 'removes stale sidecars for a video basename' do
      manager = described_class.new(enabled: true)

      old_cache = File.join(temp_dir, 'movie.loudnorm_old.json')
      fresh_cache = File.join(temp_dir, 'movie.loudnorm_new.json')
      File.write(old_cache, '{}')
      File.write(fresh_cache, '{}')

      old_time = Time.now - (31 * 24 * 60 * 60)
      fresh_time = Time.now - (2 * 24 * 60 * 60)
      File.utime(old_time, old_time, old_cache)
      File.utime(fresh_time, fresh_time, fresh_cache)

      manager.cleanup_stale_cache(video_file, max_age_days: 30)

      expect(File.exist?(old_cache)).to be(false)
      expect(File.exist?(fresh_cache)).to be(true)
    end
  end

  describe '#cache_stats' do
    it 'returns aggregate stats for cache files in a directory' do
      File.write(File.join(temp_dir, 'a.loudnorm_livingroom.json'), '{}')
      File.write(File.join(temp_dir, 'b.loudnorm_night.json'), '{}')

      stats = described_class.new(enabled: true).cache_stats(temp_dir)

      expect(stats[:enabled]).to be(true)
      expect(stats[:count]).to eq(2)
      expect(stats[:total_size_mb]).to be >= 0
    end

    it 'returns disabled stats when cache is disabled' do
      stats = described_class.new(enabled: false).cache_stats(temp_dir)
      expect(stats).to eq({ enabled: false })
    end
  end

  describe '#cache_path' do
    it 'includes basename and profile name in sidecar path' do
      manager = described_class.new(enabled: true)
      path = manager.cache_path(video_file, profile)

      expect(File.basename(path)).to eq('movie.loudnorm_livingroom.json')
    end
  end
end
