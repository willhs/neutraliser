require 'spec_helper'
require 'fileutils'

# The guards are plain: a file, the facts a Source holds, the run's options in, a Verdict out.
# No Processor, no stubbed privates. Only the folder and the free-space reading are real or stood in
# by the objects that own them (a temp folder, a DiskGuard).
RSpec.describe Neutraliser::Guards do
  let(:temp_dir) { Dir.mktmpdir }
  let(:profile) { Neutraliser::Profiles.get_profile('livingroom') }
  let(:guards) { described_class.new(**guards_options) }
  let(:video) { File.join(temp_dir, 'film.mkv') }

  before { File.write(video, 'x') }

  after do
    FileUtils.chmod(0o755, temp_dir)
    FileUtils.remove_entry(temp_dir)
  end

  def source(**fixture) = ProbeFixture.source(video, **fixture)

  describe '#writable' do
    it 'lets a file through when its folder takes a new file, leaving nothing behind' do
      expect(guards.writable(video)).to be_proceed
      expect(Dir.children(temp_dir)).to eq(['film.mkv'])
    end

    it 'fails a file in a folder it cannot write to, saying which and why', :needs_permissions do
      FileUtils.chmod(0o555, temp_dir)

      verdict = guards.writable(video)

      expect(verdict).to have_attributes(
        action: :fail, status: :failed, reason: :not_writable,
        message: "can't write to #{File.expand_path(temp_dir)} (Permission denied); fix the folder's permissions"
      )
      expect(verdict.log).to eq(["  Not writable: #{verdict.message}"])
    end

    it 'does not check on a dry run, which writes nothing' do
      FileUtils.chmod(0o555, temp_dir)

      expect(described_class.new(**guards_options(dry_run: true)).writable(video)).to be_proceed
    end

    it 'checks beside the real file when --replace goes through a symlink', :needs_permissions do
      real_dir = File.join(temp_dir, 'real')
      link_dir = File.join(temp_dir, 'links')
      FileUtils.mkdir_p([real_dir, link_dir])
      File.write(File.join(real_dir, 'film.mkv'), 'x')
      File.symlink(File.join(real_dir, 'film.mkv'), File.join(link_dir, 'film.mkv'))
      FileUtils.chmod(0o555, real_dir)

      replacing = described_class.new(**guards_options(replace: true))

      begin
        expect(replacing.writable(File.join(link_dir, 'film.mkv'))).to have_attributes(reason: :not_writable)
        expect(guards.writable(File.join(link_dir, 'film.mkv'))).to be_proceed
      ensure
        FileUtils.chmod(0o755, real_dir)
      end
    end
  end

  describe '#disk_space' do
    def with_disk(verdict, **extra)
      disk = Neutraliser::DiskGuard.new(min_free: 1)
      allow(disk).to receive(:verdict).and_return(verdict)
      described_class.new(**guards_options(disk_guard: disk, **extra))
    end

    it 'lets a file through when no floor is set' do
      expect(guards.disk_space(video)).to be_proceed
    end

    it 'skips a file when space is short, so a smaller one can still be tried' do
      verdict = with_disk(:skip).disk_space(video)

      expect(verdict).to have_attributes(action: :skip, status: :skipped, reason: :low_disk)
      expect(verdict.log).to eq(['  Not enough free space for this file, skipping'])
    end

    it 'aborts the run when space is critically low' do
      verdict = with_disk(:abort).disk_space(video)

      expect(verdict).to be_abort
      expect(verdict.message).to eq("free space on #{File.expand_path(temp_dir)} is below the abort floor")
    end

    it 'does not look on a dry run' do
      disk = Neutraliser::DiskGuard.new(abort_free: 1)
      expect(disk).not_to receive(:verdict)

      expect(described_class.new(**guards_options(disk_guard: disk, dry_run: true)).disk_space(video)).to be_proceed
    end
  end

  describe '#audio_stream' do
    it 'lets a file with audio through' do
      expect(guards.audio_stream(source)).to be_proceed
    end

    it 'skips a readable file that has no audio' do
      verdict = guards.audio_stream(source(audio: []))

      expect(verdict).to have_attributes(status: :skipped, reason: :no_audio_track, message: nil)
      expect(verdict.log).to eq(['  No audio track found, skipping'])
    end

    it 'fails a file ffprobe could not read, because it may be mid-write' do
      stub_unreadable_probe
      unreadable = Neutraliser::Source.new(video)

      expect(guards.audio_stream(unreadable)).to have_attributes(status: :failed, reason: :unreadable)
    end
  end

  describe '#subtitles' do
    it 'lets copyable subtitles through' do
      expect(guards.subtitles(source(subtitles: ['subrip']))).to be_proceed
    end

    it 'fails a file with a subtitle ffmpeg cannot copy, naming it' do
      verdict = guards.subtitles(source(subtitles: [nil], stderr: ProbeFixture.unknown_subtitle_stderr('S_TEXT/WEBVTT')))

      expect(verdict).to have_attributes(status: :failed, reason: :unsupported_subtitle)
      expect(verdict.message).to start_with("subtitle stream 2 (S_TEXT/WEBVTT) can't be copied")
    end
  end

  describe '#object_audio' do
    let(:atmos) { ProbeFixture.audio(codec: 'eac3', profile: 'Dolby Digital Plus + Dolby Atmos', channels: 6) }

    it 'skips an Atmos track, recording it as left alone rather than done' do
      verdict = guards.object_audio(video, source(audio: [atmos]))

      expect(verdict).to have_attributes(status: :skipped, reason: :object_audio, message: 'Dolby Digital Plus + Dolby Atmos')
      expect(verdict.left).to have_attributes(reason: 'object_audio', message: 'Dolby Digital Plus + Dolby Atmos',
                                              profile: 'livingroom')
      expect(verdict.log.first).to match(/Object audio \(Dolby Digital Plus \+ Dolby Atmos\).*--allow-object-audio-loss/)
    end

    it 'lets it through with a warning when the user accepted the loss' do
      verdict = described_class.new(**guards_options(allow_object_audio_loss: true)).object_audio(video, source(audio: [atmos]))

      expect(verdict).to be_proceed
      expect(verdict.log.first).to match(/Warning: primary track is Dolby Digital Plus \+ Dolby Atmos; re-encoding drops/)
    end

    it 'lets a plain track through quietly' do
      verdict = guards.object_audio(video, source(audio: [ProbeFixture.audio(codec: 'aac', channels: 6)]))

      expect(verdict).to be_proceed
      expect(verdict.log).to be_empty
    end

    context 'when the name says Atmos but neither probe finds it' do
      let(:video) { File.join(temp_dir, 'Show.S01E01.DDP5.1.Atmos.mkv') }
      let(:plain) { source(audio: [ProbeFixture.audio(codec: 'eac3', channels: 6)]) }

      before { allow(Neutraliser::FFmpegWrapper).to receive(:probe_audio_profile_mid_file).and_return(nil) }

      it 'goes on with a note when this ffmpeg could have named it' do
        verdict = guards.object_audio(video, plain)

        expect(verdict).to be_proceed
        expect(verdict.log.first).to match(/name suggests object audio but ffprobe found none/)
      end

      it 'skips when this ffmpeg is too old to have named it' do
        verdict = described_class.new(**guards_options(object_audio_undetectable: true)).object_audio(video, plain)

        expect(verdict).to have_attributes(status: :skipped, reason: :object_audio, message: 'suspected from the name')
        expect(verdict.left).to have_attributes(reason: 'object_audio', message: 'suspected from the name')
      end

      it 'goes on when it is too old but the user accepted the loss' do
        verdict = described_class.new(**guards_options(object_audio_undetectable: true, allow_object_audio_loss: true))
                                 .object_audio(video, plain)

        expect(verdict).to be_proceed
      end
    end
  end

  describe '#codec_change' do
    let(:dts) { source(audio: [ProbeFixture.audio(codec: 'dts', channels: 6, bit_rate: '1509000')]) }

    it 'skips a track whose codec cannot be kept, recording it as left alone' do
      verdict = guards.codec_change(video, dts)

      expect(verdict).to have_attributes(status: :skipped, reason: :codec_change, message: 'dts would be re-encoded as flac')
      expect(verdict.left).to have_attributes(reason: 'codec_change', message: 'dts would be re-encoded as flac')
      expect(verdict.log.first).to match(/Codec change.*--allow-codec-change/)
    end

    it 'goes on under --allow-codec-change' do
      expect(described_class.new(**guards_options(allow_codec_change: true)).codec_change(video, dts)).to be_proceed
    end

    it 'lets a codec that is kept through' do
      expect(guards.codec_change(video, source(audio: [ProbeFixture.audio(codec: 'aac')]))).to be_proceed
    end
  end

  describe 'the sequences' do
    it 'before staging: the first guard to stop the file decides, and later ones are not asked', :needs_permissions do
      FileUtils.chmod(0o555, temp_dir)

      verdict = guards.before_staging(video, source(audio: []))

      expect(verdict.reason).to eq(:not_writable)
    end

    it 'before staging: a file that passes everything proceeds' do
      expect(guards.before_staging(video, source)).to be_proceed
    end

    it 'before staging: an abort ends the run before the file is probed' do
      disk = Neutraliser::DiskGuard.new(abort_free: 1)
      allow(disk).to receive(:verdict).and_return(:abort)
      unprobed = instance_double(Neutraliser::Source)
      expect(unprobed).not_to receive(:readable?)

      expect(described_class.new(**guards_options(disk_guard: disk)).before_staging(video, unprobed)).to be_abort
    end

    it 'after staging: the lines of a guard that let the file through come before the one that stopped it' do
      atmos_named = File.join(temp_dir, 'Film.Atmos.mkv')
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_audio_profile_mid_file).and_return(nil)
      dts = ProbeFixture.source(atmos_named, audio: [ProbeFixture.audio(codec: 'dts', channels: 6)])

      verdict = guards.after_staging(atmos_named, dts)

      expect(verdict).to have_attributes(reason: :codec_change)
      expect(verdict.log.length).to be >= 1
    end

    it 'after staging: a plain AAC track proceeds' do
      expect(guards.after_staging(video, source)).to be_proceed
    end
  end

  def guards_options(**overrides)
    { profile: profile, replace: false, dry_run: false, disk_guard: Neutraliser::DiskGuard.new,
      allow_object_audio_loss: false, allow_codec_change: false }.merge(overrides)
  end
end
