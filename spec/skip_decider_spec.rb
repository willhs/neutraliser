require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::SkipDecider do
  let(:temp_dir) { Dir.mktmpdir }
  let(:profile) { { name: 'livingroom', lufs: -20.0, tp: -1.5, lra: 12.0 } }
  let(:video_path) { File.join(temp_dir, 'movie.mp4') }

  before do
    File.write(video_path, 'x' * 100)
    allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(nil)
  end
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

    it 'ignores a sidecar that cannot be read' do
      sidecar = File.join(temp_dir, '.neutraliser')
      File.write(sidecar, '{}')
      allow(File).to receive(:read).with(sidecar).and_raise(Errno::EACCES, 'permission denied')

      decider = described_class.new(temp_dir)

      expect(decider.already_processed?(video_path, profile)).to be false
    end
  end

  describe 'the in-file NEUTRALISER_* stamp' do
    def stamped(profile_name)
      Neutraliser::Stamp.now(profile: profile_name, mode: 'linear', gain_db: 1.0, source_codec: 'aac',
                             source_bitrate: nil, measured_i: -21.0, measured_tp: -5.0, measured_lra: 6.0)
    end

    it 'counts a file stamped for the same profile as processed, with no sidecar (moved, or a new root)' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).with(video_path).and_return(stamped('livingroom'))
      other_root = Dir.mktmpdir

      expect(described_class.new(other_root).already_processed?(video_path, profile)).to be true
    ensure
      FileUtils.remove_entry(other_root)
    end

    it 'does not count a stamp for a different profile' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).with(video_path).and_return(stamped('night'))

      expect(described_class.new(temp_dir).already_processed?(video_path, profile)).to be false
    end

    it 'refreshes the sidecar cache on a tag hit, so the next check skips the probe' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).with(video_path).and_return(stamped('livingroom'))
      described_class.new(temp_dir).already_processed?(video_path, profile)

      next_run = described_class.new(temp_dir)
      expect(Neutraliser::FFmpegWrapper).not_to receive(:read_stamp)
      expect(next_run.already_processed?(video_path, profile)).to be true
    end

    it 'lets #skip? short-circuit on the stamp without a quick sample' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).with(video_path).and_return(stamped('livingroom'))

      expect(Neutraliser::FFmpegWrapper).not_to receive(:quick_loudness_sample)
      expect(described_class.new(temp_dir).skip?(video_path, profile, tolerance: 1.0)).to be true
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
      allow(Neutraliser::FFmpegWrapper).to receive_messages(quick_loudness_sample: quick_result, primary_audio_index: 0)

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
      allow(Neutraliser::FFmpegWrapper).to receive_messages(quick_loudness_sample: quick_result, primary_audio_index: 0)

      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be false
    end

    it 'falls back to full analysis when the quick sample raises' do
      decider = described_class.new(temp_dir, fast_verification: true)
      allow(Neutraliser::FFmpegWrapper).to receive(:quick_loudness_sample).and_raise(StandardError, 'boom')

      expect(decider.skip?(video_path, profile, tolerance: 1.0)).to be false
    end
  end
end
