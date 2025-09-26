require 'spec_helper'
require 'tempfile'
require 'fileutils'
require 'json'

RSpec.describe Neutraliser::CacheManager do
  let(:temp_dir) { Dir.mktmpdir }
  let(:video_file) { File.join(temp_dir, 'test_video.mp4') }
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:measured_data) do
    {
      'input_i' => '-18.5',
      'input_tp' => '-2.1',
      'input_lra' => '8.3',
      'input_thresh' => '-28.9',
      'target_offset' => '1.5'
    }
  end

  before do
    File.write(video_file, 'fake video content')
  end

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe '#initialize' do
    context 'with cache enabled' do
      it 'sets enabled flag to true' do
        manager = described_class.new(enabled: true)
        expect(manager.instance_variable_get(:@enabled)).to be true
      end
    end

    context 'with cache disabled' do
      it 'sets enabled flag to false' do
        manager = described_class.new(enabled: false)
        expect(manager.instance_variable_get(:@enabled)).to be false
      end
    end
  end

  describe '#cache_path' do
    let(:manager) { described_class.new(enabled: true) }

    it 'generates correct cache path with profile name' do
      expected_path = File.join(temp_dir, 'test_video.loudnorm_livingroom.json')
      result = manager.cache_path(video_file, profile)
      expect(result).to eq(expected_path)
    end

    it 'handles different file extensions' do
      mkv_file = File.join(temp_dir, 'movie.mkv')
      result = manager.cache_path(mkv_file, profile)
      expect(result).to end_with('movie.loudnorm_livingroom.json')
    end

    it 'uses profile name in cache filename' do
      night_profile = { name: 'night', lufs: -16.0 }
      result = manager.cache_path(video_file, night_profile)
      expect(result).to include('loudnorm_night.json')
    end
  end

  describe '#save_analysis' do
    let(:manager) { described_class.new(enabled: true) }

    it 'saves analysis data to JSON file' do
      manager.save_analysis(video_file, profile, measured_data)

      cache_file = manager.cache_path(video_file, profile)
      expect(File.exist?(cache_file)).to be true

      saved_data = JSON.parse(File.read(cache_file))
      expect(saved_data['analysis']).to eq(measured_data)
      expect(saved_data['profile']).to eq(profile.transform_keys(&:to_s))
    end

    it 'includes file metadata in cache' do
      manager.save_analysis(video_file, profile, measured_data)

      cache_file = manager.cache_path(video_file, profile)
      saved_data = JSON.parse(File.read(cache_file))

      expect(saved_data['file_size']).to eq(File.size(video_file))
      expect(saved_data['file_mtime']).to eq(File.mtime(video_file).to_i)
    end

    it 'includes timestamp in cache' do
      freeze_time = Time.parse('2023-10-15 12:00:00')
      allow(Time).to receive(:now).and_return(freeze_time)

      manager.save_analysis(video_file, profile, measured_data)

      cache_file = manager.cache_path(video_file, profile)
      saved_data = JSON.parse(File.read(cache_file))

      expect(saved_data['timestamp']).to eq(freeze_time.to_i)
    end

    context 'when cache is disabled' do
      let(:manager) { described_class.new(enabled: false) }

      it 'does not create cache file' do
        manager.save_analysis(video_file, profile, measured_data)

        cache_file = manager.cache_path(video_file, profile)
        expect(File.exist?(cache_file)).to be false
      end
    end
  end

  describe '#load_cached_analysis' do
    let(:manager) { described_class.new(enabled: true) }

    context 'with valid cache file' do
      before do
        manager.save_analysis(video_file, profile, measured_data)
      end

      it 'loads cached analysis data' do
        result = manager.load_cached_analysis(video_file, profile)
        expect(result).to eq(measured_data)
      end

      it 'validates file has not changed' do
        # Modify file after caching
        sleep 0.1  # Ensure different mtime
        File.write(video_file, 'modified content')

        result = manager.load_cached_analysis(video_file, profile)
        expect(result).to be_nil
      end

      it 'validates profile matches' do
        different_profile = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }
        result = manager.load_cached_analysis(video_file, different_profile)
        expect(result).to be_nil
      end
    end

    context 'with nonexistent cache file' do
      it 'returns nil' do
        result = manager.load_cached_analysis(video_file, profile)
        expect(result).to be_nil
      end
    end

    context 'with corrupted cache file' do
      before do
        cache_file = manager.cache_path(video_file, profile)
        File.write(cache_file, 'invalid json')
      end

      it 'returns nil and does not crash' do
        result = manager.load_cached_analysis(video_file, profile)
        expect(result).to be_nil
      end
    end

    context 'when cache is disabled' do
      let(:manager) { described_class.new(enabled: false) }

      it 'returns nil without checking files' do
        result = manager.load_cached_analysis(video_file, profile)
        expect(result).to be_nil
      end
    end
  end

  describe '#cleanup_stale_cache' do
    let(:manager) { described_class.new(enabled: true) }

    context 'with stale cache files' do
      before do
        # Create cache files for different profiles
        manager.save_analysis(video_file, profile, measured_data)

        night_profile = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }
        manager.save_analysis(video_file, night_profile, measured_data)
      end

      it 'removes all cache files for the video file' do
        livingroom_cache = manager.cache_path(video_file, profile)
        night_profile = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }
        night_cache = manager.cache_path(video_file, night_profile)

        expect(File.exist?(livingroom_cache)).to be true
        expect(File.exist?(night_cache)).to be true

        manager.cleanup_stale_cache(video_file)

        expect(File.exist?(livingroom_cache)).to be false
        expect(File.exist?(night_cache)).to be false
      end

      it 'does not remove cache files for other videos' do
        other_video = File.join(temp_dir, 'other_video.mp4')
        File.write(other_video, 'other content')
        manager.save_analysis(other_video, profile, measured_data)

        other_cache = manager.cache_path(other_video, profile)
        expect(File.exist?(other_cache)).to be true

        manager.cleanup_stale_cache(video_file)

        expect(File.exist?(other_cache)).to be true
      end
    end

    context 'when cache is disabled' do
      let(:manager) { described_class.new(enabled: false) }

      it 'does nothing' do
        # Should not raise any errors
        manager.cleanup_stale_cache(video_file)
      end
    end
  end

  describe '#cache_stats' do
    let(:manager) { described_class.new(enabled: true) }

    before do
      # Create cache files
      manager.save_analysis(video_file, profile, measured_data)

      other_video = File.join(temp_dir, 'other_video.mp4')
      File.write(other_video, 'other content')
      manager.save_analysis(other_video, profile, measured_data)
    end

    it 'returns statistics about cache files' do
      stats = manager.cache_stats(temp_dir)

      expect(stats[:total_files]).to eq(2)
      expect(stats[:total_size]).to be > 0
      expect(stats[:profiles]).to include('livingroom')
    end

    it 'groups files by profile' do
      night_profile = { name: 'night', lufs: -16.0, tp: -1.5, lra: 10.0 }
      manager.save_analysis(video_file, night_profile, measured_data)

      stats = manager.cache_stats(temp_dir)

      expect(stats[:profiles]).to include('livingroom', 'night')
    end

    context 'with empty directory' do
      let(:empty_dir) { File.join(temp_dir, 'empty') }

      before do
        Dir.mkdir(empty_dir)
      end

      it 'returns zero statistics' do
        stats = manager.cache_stats(empty_dir)

        expect(stats[:total_files]).to eq(0)
        expect(stats[:total_size]).to eq(0)
        expect(stats[:profiles]).to eq([])
      end
    end
  end

  describe 'file validation' do
    let(:manager) { described_class.new(enabled: true) }

    describe '#file_changed?' do
      it 'detects when file size changes' do
        manager.save_analysis(video_file, profile, measured_data)

        # Change file size
        File.write(video_file, 'different size content here')

        result = manager.send(:file_changed?, video_file, {
          'file_size' => File.size(video_file) - 10,  # Wrong size
          'file_mtime' => File.mtime(video_file).to_i
        })

        expect(result).to be true
      end

      it 'detects when file modification time changes' do
        manager.save_analysis(video_file, profile, measured_data)

        # Change mtime
        future_time = Time.now + 3600
        File.utime(future_time, future_time, video_file)

        result = manager.send(:file_changed?, video_file, {
          'file_size' => File.size(video_file),
          'file_mtime' => File.mtime(video_file).to_i - 3600  # Wrong mtime
        })

        expect(result).to be true
      end

      it 'returns false when file has not changed' do
        manager.save_analysis(video_file, profile, measured_data)

        result = manager.send(:file_changed?, video_file, {
          'file_size' => File.size(video_file),
          'file_mtime' => File.mtime(video_file).to_i
        })

        expect(result).to be false
      end
    end

    describe '#profiles_match?' do
      it 'returns true for identical profiles' do
        result = manager.send(:profiles_match?, profile, profile.transform_keys(&:to_s))
        expect(result).to be true
      end

      it 'returns false for different LUFS values' do
        different_profile = profile.merge(lufs: -16.0).transform_keys(&:to_s)
        result = manager.send(:profiles_match?, profile, different_profile)
        expect(result).to be false
      end

      it 'returns false for different profile names' do
        different_profile = profile.merge(name: 'night').transform_keys(&:to_s)
        result = manager.send(:profiles_match?, profile, different_profile)
        expect(result).to be false
      end
    end
  end
end