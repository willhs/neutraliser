require 'spec_helper'

RSpec.describe Neutraliser::FileResult do
  # The run manifest holds these as strings, and --resume reads manifests written by older
  # versions, so a reason being renamed or dropped breaks resuming a run begun before the upgrade.
  it 'keeps every reason the manifest has ever held' do
    all = described_class::REASONS.values.flatten.map(&:to_s)

    expect(all).to include(*%w[normalized dry_run already_processed unsupported_format no_audio_track low_disk silent
                               peak_limited within_tolerance object_audio codec_change unreadable not_writable
                               unsupported_subtitle timeout output_verification_failed source_changed ffmpeg_error
                               file_manager_error processing_error invalid_result])
  end

  it 'refuses a reason that does not belong to the status' do
    expect { described_class.skipped('a.mkv', :timeout) }.to raise_error(ArgumentError, /not a reason for a skipped file/)
    expect { described_class.done('a.mkv', :typo) }.to raise_error(ArgumentError)
    expect { described_class.new(file: 'a.mkv', status: :weird, reason: :normalized) }.to raise_error(ArgumentError, /unknown status/)
  end

  it 'answers its status' do
    expect(described_class.done('a.mkv', :normalized)).to be_done
    expect(described_class.skipped('a.mkv', :silent)).to be_skipped
    expect(described_class.failed('a.mkv', :timeout)).to be_failed
  end

  it 'carries the mode and the left record of a result' do
    left = Neutraliser::LeftRecord.for(:codec_change, Neutraliser::Profiles.get_profile('livingroom'), message: 'm')

    expect(described_class.done('a.mkv', :normalized, mode: Neutraliser::Mode::LIMITED).mode).to eq(Neutraliser::Mode::LIMITED)
    expect(described_class.skipped('a.mkv', :codec_change, left: left).left).to eq(left)
  end

  describe 'the reasons --resume takes as final' do
    it 'reads manifest strings, spelt as ever' do
      %w[normalized already_processed no_audio_track unsupported_format].each do |text|
        expect(described_class.final_reason?(text)).to be(true)
      end
      %w[dry_run low_disk timeout object_audio codec_change within_tolerance peak_limited].each do |text|
        expect(described_class.final_reason?(text)).to be(false)
      end
      expect(described_class.final_reason?(nil)).to be(false)
    end

    it 'only names reasons a file can end with' do
      expect(described_class::FINAL_REASONS - described_class::REASONS.values.flatten).to be_empty
    end
  end

  describe '.from_error' do
    {
      Neutraliser::FFmpegTimeoutError.new('t') => [:timeout, 'Timed out processing file'],
      Neutraliser::OutputVerificationError.new('o') => [:output_verification_failed, 'Output verification failed'],
      Neutraliser::SourceChangedError.new('s') => [:source_changed, 'Source changed'],
      Neutraliser::FFmpegError.new('f') => [:ffmpeg_error, 'FFmpeg error processing file'],
      Neutraliser::FFmpegError.new('f', reason: :not_writable) => [:not_writable, 'FFmpeg error processing file'],
      Neutraliser::FileManagerError.new('m') => [:file_manager_error, 'File management error processing file'],
      StandardError.new('x') => [:processing_error, 'Error processing file']
    }.each do |error, (reason, label)|
      it "turns #{error.class} (#{reason}) into a failed #{reason} result worded #{label.inspect}" do
        result = described_class.from_error('a.mkv', error)

        expect(result).to have_attributes(status: :failed, reason: reason, message: error.message)
        expect(described_class.error_label(error)).to eq(label)
      end
    end
  end
end
