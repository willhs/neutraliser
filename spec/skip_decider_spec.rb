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

  describe 'a sidecar in the file\'s own folder (written by import-manifest)' do
    it 'counts for a run started higher up, whatever the run root' do
      season = File.join(temp_dir, 'show', 'season1')
      FileUtils.mkdir_p(season)
      episode = File.join(season, 'e1.mkv')
      File.write(episode, 'x' * 50)
      described_class.new(season).mark_processed(episode, profile)

      expect(described_class.new(temp_dir).already_processed?(episode, profile)).to be true
    end

    it 'still checks size, mtime and profile' do
      season = File.join(temp_dir, 'season1')
      FileUtils.mkdir_p(season)
      episode = File.join(season, 'e1.mkv')
      File.write(episode, 'x' * 50)
      described_class.new(season).mark_processed(episode, profile)
      File.write(episode, 'replaced with something else')

      expect(described_class.new(temp_dir).already_processed?(episode, profile)).to be false
      expect(described_class.new(temp_dir).already_processed?(episode, profile.merge(name: 'night'))).to be false
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

  describe 'recipes' do
    let(:stamp_for) do
      lambda do |recipe|
        Neutraliser::Stamp.now(profile: 'livingroom', recipe: recipe, mode: 'linear', gain_db: 3.0, source_codec: 'aac',
                               source_bitrate: nil, measured_i: -23.0, measured_tp: -6.0, measured_lra: 5.0)
      end
    end

    before { stub_const('Neutraliser::Recipe::CURRENT', 2) }

    it 'counts a file made by any recipe as done, so a new default never re-levels on its own' do
      [1, nil, 2].each do |recipe|
        allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(stamp_for.call(recipe))

        FileUtils.rm_f(File.join(temp_dir, '.neutraliser'))

        expect(described_class.new(temp_dir).already_processed?(video_path, profile)).to be true
      end
    end

    it 'does the files of a named recipe over, and no others' do
      redo_old = described_class.new(temp_dir, redo_recipes: [1])

      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(stamp_for.call(1))
      expect(redo_old.already_processed?(video_path, profile)).to be false
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(stamp_for.call(2))
      expect(redo_old.already_processed?(video_path, profile)).to be true
    end

    it 'does unversioned files over when asked, and not before' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(stamp_for.call(nil))

      expect(described_class.new(temp_dir).already_processed?(video_path, profile)).to be true
      expect(described_class.new(temp_dir, redo_recipes: [nil]).already_processed?(video_path, profile)).to be false
    end

    it 'remembers a tag hit under the file\'s own recipe, not the current one' do
      allow(Neutraliser::FFmpegWrapper).to receive(:read_stamp).and_return(stamp_for.call(1))
      described_class.new(temp_dir).already_processed?(video_path, profile)

      entry = JSON.parse(File.read(File.join(temp_dir, '.neutraliser')))['movie.mp4']
      expect(entry['recipe']).to eq(1)
      # So a later redo of recipe 1 is not hidden by the cached verdict.
      expect(described_class.new(temp_dir, redo_recipes: [1]).already_processed?(video_path, profile)).to be false
    end

    it 'records the current recipe for a file it marks processed' do
      described_class.new(temp_dir).mark_processed(video_path, profile)

      expect(JSON.parse(File.read(File.join(temp_dir, '.neutraliser')))['movie.mp4']).to include('recipe' => 2)
    end

    it 'leaves the recipe off an entry that predates recipes, and still honours it' do
      File.write(File.join(temp_dir, '.neutraliser'), JSON.generate(
                                                        'movie.mp4' => { 'size' => File.size(video_path), 'mtime' => File.mtime(video_path).to_i,
                                                                         'profile' => 'livingroom' }
                                                      ))

      expect(described_class.new(temp_dir).already_processed?(video_path, profile)).to be true
      expect(described_class.new(temp_dir, redo_recipes: [nil]).already_processed?(video_path, profile)).to be false
    end
  end

  describe 'left-alone records' do
    let(:record) do
      Neutraliser::LeftRecord.new(reason: 'peak_limited', profile: 'livingroom', recipe: 1, message: 'peaky',
                                  measured_i: -30.0, measured_tp: -0.5, measured_lra: 4.0)
    end

    it 'keeps a record that is never mistaken for done' do
      decider = described_class.new(temp_dir)
      decider.mark_left(video_path, record)

      expect(decider.already_processed?(video_path, profile)).to be false
      expect(described_class.new(temp_dir).already_processed?(video_path, profile)).to be false
      expect(described_class.new(temp_dir).left_record(video_path)).to eq(record)
    end

    it 'is replaced when the file is marked processed' do
      decider = described_class.new(temp_dir)
      decider.mark_left(video_path, record)
      decider.mark_processed(video_path, profile)

      expect(decider.left_record(video_path)).to be_nil
      expect(decider.already_processed?(video_path, profile)).to be true
    end

    it 'goes stale when the file changes' do
      decider = described_class.new(temp_dir)
      decider.mark_left(video_path, record)
      File.write(video_path, 'x' * 300)

      expect(decider.left_record(video_path)).to be_nil
    end

    it 'is found from a folder above, where the run that wrote it started' do
      sub = File.join(temp_dir, 'Show', 'S01')
      FileUtils.mkdir_p(sub)
      episode = File.join(sub, 'e1.mkv')
      File.write(episode, 'y' * 50)
      described_class.new(temp_dir).mark_left(episode, record)

      expect(described_class.left_record_for(episode)).to eq(record)
      expect(described_class.left_record_for(video_path)).to be_nil
    end

    it 'keeps the measured levels of a close-enough file beside its processed entry' do
      within = record.with(reason: 'within_tolerance')
      decider = described_class.new(temp_dir)
      decider.mark_processed(video_path, profile, tolerance: 1.0, left: within)

      expect(decider.already_processed?(video_path, profile)).to be true
      expect(described_class.new(temp_dir).left_record(video_path)).to eq(within)
    end
  end
end
