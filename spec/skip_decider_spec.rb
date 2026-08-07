require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::SkipDecider do
  let(:temp_dir) { Dir.mktmpdir }
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:video_path) { File.join(temp_dir, 'movie.mp4') }

  before { File.write(video_path, 'x' * 100) }
  after { FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir) }

  describe '#already_processed? / #mark_processed' do
    it 'is false before the file has been marked' do
      decider = described_class.new(temp_dir)
      expect(decider.already_processed?(video_path, profile)).to be false
    end

    it 'is true after marking, for the same size/mtime/profile' do
      decider = described_class.new(temp_dir)
      decider.mark_processed(video_path, profile)

      expect(decider.already_processed?(video_path, profile)).to be true
    end

    it 'persists to a single sidecar file: .neutraliser' do
      decider = described_class.new(temp_dir)
      decider.mark_processed(video_path, profile)

      expect(File.exist?(File.join(temp_dir, '.neutraliser'))).to be true
      expect(Dir.glob(File.join(temp_dir, '.*neutralised_*'))).to be_empty
    end

    it 'is false once the file has changed size (never expires by age)' do
      decider = described_class.new(temp_dir)
      decider.mark_processed(video_path, profile)
      File.write(video_path, 'x' * 200)

      expect(decider.already_processed?(video_path, profile)).to be false
    end

    it 'is false for a different profile' do
      decider = described_class.new(temp_dir)
      decider.mark_processed(video_path, profile)

      other_profile = profile.merge(name: 'night')
      expect(decider.already_processed?(video_path, other_profile)).to be false
    end
  end

  describe '#skip?' do
    it 'returns true without sampling when already processed' do
      decider = described_class.new(temp_dir, fast_verification: true)
      decider.mark_processed(video_path, profile)

      expect(Neutraliser::FFmpegWrapper).not_to receive(:quick_loudness_sample)
      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be true
    end

    it 'returns false without sampling when fast verification is disabled' do
      decider = described_class.new(temp_dir, fast_verification: false)

      expect(Neutraliser::FFmpegWrapper).not_to receive(:quick_loudness_sample)
      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be false
    end

    it 'marks the sidecar (not a separate marker file) when a quick sample verifies within tolerance' do
      decider = described_class.new(temp_dir, fast_verification: true)
      quick_result = Neutraliser::Measurement.already_at_target(profile)
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_return(quick_result)

      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be true
      expect(decider.already_processed?(video_path, profile)).to be true
      expect(Dir.glob(File.join(temp_dir, '.*neutralised_*'))).to be_empty
    end

    it 'applies an explicit, documented safety margin rather than scaling tolerance silently' do
      decider = described_class.new(temp_dir, fast_verification: true)
      # 0.9 LU off target: within a raw 1.0 tolerance, but outside the
      # (tolerance - QUICK_SAMPLE_SAFETY_MARGIN_LU) = 0.8 quick-sample band.
      quick_result = Neutraliser::Measurement.from_loudnorm_json(
        'input_i' => (profile[:lufs] + 0.9).to_s, 'input_tp' => '0', 'input_lra' => '0',
        'input_thresh' => '0', 'target_offset' => '0'
      )
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_return(quick_result)

      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be false
    end

    it 'falls back to full analysis when the quick sample raises' do
      decider = described_class.new(temp_dir, fast_verification: true)
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_raise(StandardError, 'boom')

      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be false
    end
  end
end
