require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::FileManager do
  let(:temp_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir)
  end

  describe '.atomic_replace' do
    it 'replaces target file with source file content' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      described_class.atomic_replace(source, target)

      expect(File.read(target)).to eq('new')
      expect(File.exist?(source)).to be(false)
      expect(File.exist?("#{target}.bak")).to be(false)
    end

    it 'raises when target file does not exist' do
      source = File.join(temp_dir, 'source.mp4')
      File.write(source, 'new')

      expect { described_class.atomic_replace(source, File.join(temp_dir, 'missing.mp4')) }
        .to raise_error(Neutraliser::FileManagerError, /Target file does not exist/)
    end

    it 'raises when source file does not exist' do
      target = File.join(temp_dir, 'target.mp4')
      File.write(target, 'old')

      expect { described_class.atomic_replace(File.join(temp_dir, 'missing.mp4'), target) }
        .to raise_error(Neutraliser::FileManagerError, /Source file does not exist/)
    end

    it 'never leaves target_path missing partway through (single rename, no backup-swap window)' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      seen_missing = false
      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        seen_missing = true unless File.exist?(target)
        original.call(*args)
      end

      described_class.atomic_replace(source, target)

      expect(seen_missing).to be(false)
      expect(File.exist?(target)).to be(true)
    end

    it 'raises FileManagerError and leaves both files untouched on cross-filesystem rename (EXDEV)' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')

      allow(File).to receive(:rename).with(source, target).and_raise(Errno::EXDEV, 'cross-device link')

      expect { described_class.atomic_replace(source, target) }
        .to raise_error(Neutraliser::FileManagerError, /different filesystems/)

      expect(File.read(target)).to eq('old')
      expect(File.read(source)).to eq('new')
    end

    it 'preserves the original file permission bits' do
      source = File.join(temp_dir, 'source.mp4')
      target = File.join(temp_dir, 'target.mp4')
      File.write(source, 'new')
      File.write(target, 'old')
      File.chmod(0o600, target)

      described_class.atomic_replace(source, target)

      expect(File.stat(target).mode & 0o7777).to eq(0o600)
    end
  end

  describe '.atomic_write' do
    it 'writes content that is fully readable back (no partial/truncated state observable)' do
      path = File.join(temp_dir, '.neutraliser')

      described_class.atomic_write(path, '{"a":1}')

      expect(File.read(path)).to eq('{"a":1}')
    end

    it 'never exposes the destination path missing or truncated mid-write' do
      path = File.join(temp_dir, 'cache.json')
      File.write(path, 'original content')

      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        expect(File.read(path)).to eq('original content')
        original.call(*args)
      end

      described_class.atomic_write(path, 'new content')

      expect(File.read(path)).to eq('new content')
    end

    it 'cleans up the temp file and re-raises if the write fails' do
      path = File.join(temp_dir, 'cache.json')
      allow_any_instance_of(File).to receive(:write).and_raise(Errno::ENOSPC, 'no space left on device')

      expect { described_class.atomic_write(path, 'content') }.to raise_error(Errno::ENOSPC)
      expect(Dir.glob(File.join(temp_dir, '.*_neutraliser_*'))).to be_empty
    end

    it 'cleans up the temp file when the write is interrupted' do
      path = File.join(temp_dir, 'cache.json')
      allow_any_instance_of(File).to receive(:write).and_raise(Interrupt)

      expect { described_class.atomic_write(path, 'content') }.to raise_error(Interrupt)
      expect(Dir.glob(File.join(temp_dir, '.*_neutraliser_*'))).to be_empty
    end

    it 'creates new sidecars with private permissions' do
      path = File.join(temp_dir, 'cache.json')

      described_class.atomic_write(path, 'content')

      expect(File.stat(path).mode & 0o7777).to eq(0o600)
    end
  end

  describe '.atomic_copy' do
    it 'publishes a completed copy and preserves existing destination permissions' do
      source = File.join(temp_dir, 'source.mp4')
      destination = File.join(temp_dir, 'destination.mp4')
      File.write(source, 'new content')
      File.write(destination, 'old content')
      File.chmod(0o600, destination)

      described_class.atomic_copy(source, destination)

      expect(File.read(destination)).to eq('new content')
      expect(File.stat(destination).mode & 0o7777).to eq(0o600)
    end

    it 'leaves an existing destination untouched and cleans up after a partial-copy failure' do
      source = File.join(temp_dir, 'source.mp4')
      destination = File.join(temp_dir, 'destination.mp4')
      File.write(source, 'new content')
      File.write(destination, 'old content')
      allow(IO).to receive(:copy_stream).and_raise(Errno::ENOSPC, 'no space left on device')

      expect { described_class.atomic_copy(source, destination) }.to raise_error(Errno::ENOSPC)

      expect(File.read(destination)).to eq('old content')
      expect(Dir.glob(File.join(temp_dir, '.*_neutraliser_*'))).to be_empty
    end
  end

  describe '.safe_temp_path' do
    it 'creates a neutraliser temp filename in the same directory' do
      original = File.join(temp_dir, 'movie.mkv')
      temp_path = described_class.safe_temp_path(original)

      expect(File.dirname(temp_path)).to eq(temp_dir)
      expect(File.basename(temp_path)).to match(/^\.movie_neutraliser_[0-9a-f]{16}\.mkv$/)
    end
  end

  describe '.verify_file_integrity' do
    let(:video) { File.join(temp_dir, 'video.mp4') }

    before do
      File.write(video, 'content')
    end

    it 'returns true when the probe succeeds and duration is present' do
      stub_probe(duration: 12.3)

      expect(described_class.verify_file_integrity(video)).to be(true)
    end

    it 'returns false when the probe reports no usable duration (corrupt output)' do
      stub_probe(duration: nil)

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'returns false when ffprobe cannot read the output' do
      stub_unreadable_probe

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'returns false when the probe times out (treated as unverifiable output, not an environment problem)' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Neutraliser::FFmpegTimeoutError, 'timed out')

      expect(described_class.verify_file_integrity(video)).to be(false)
    end

    it 'raises FileManagerError, distinct from a corrupt-output false, when ffprobe is missing' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_raise(Errno::ENOENT, 'ffprobe')

      expect { described_class.verify_file_integrity(video) }
        .to raise_error(Neutraliser::FileManagerError, /ffprobe not found/)
    end

    it 'uses the Source it is handed, so the output is probed once for the integrity check and the comparison' do
      allow(Neutraliser::FFmpegWrapper).to receive(:probe_file).and_return([ProbeFixture.json, ''])
      output = Neutraliser::Source.new(video)

      described_class.verify_file_integrity(video, output)
      described_class.output_mismatch(ProbeFixture.source('in.mkv'), output, expected_audio_streams: 1)

      expect(Neutraliser::FFmpegWrapper).to have_received(:probe_file).once
    end

    it 'returns false for missing files' do
      expect(described_class.verify_file_integrity(File.join(temp_dir, 'missing.mp4'))).to be(false)
    end
  end

  describe '.output_mismatch' do
    let(:two_tracks) { [ProbeFixture.audio(language: 'eng', default: true), ProbeFixture.audio(language: 'spa')] }
    let(:source) { ProbeFixture.source('in.mkv', audio: two_tracks, duration: 60.0) }

    def written(**fixture) = ProbeFixture.source('out.mkv', audio: two_tracks, duration: 60.0, **fixture)

    it 'is nil for a faithful rewrite' do
      expect(described_class.output_mismatch(source, written, expected_audio_streams: 2)).to be_nil
    end

    it 'flags a truncated output' do
      expect(described_class.output_mismatch(source, written(duration: 3.0), expected_audio_streams: 2))
        .to eq('output is 3.0s long, source is 60.0s')
    end

    it 'flags a dropped audio stream' do
      expect(described_class.output_mismatch(source, written, expected_audio_streams: 3))
        .to eq('output has 2 audio stream(s), expected 3')
    end

    it 'does not count an output that shows no audio at all' do
      expect(described_class.output_mismatch(source, written(audio: []), expected_audio_streams: 1))
        .to eq('output has 0 audio stream(s), expected 1')
    end

    it 'flags a lost video stream, subtitle, attachment or chapter' do
      with_extras = ProbeFixture.source('in.mkv', audio: two_tracks, subtitles: ['subrip'], attachments: 1, chapters: 3, duration: 60.0)

      expect(described_class.output_mismatch(with_extras, written(subtitles: ['subrip'], attachments: 1, chapters: 2), expected_audio_streams: 2))
        .to eq('output has 2 chapter(s), source has 3')
      expect(described_class.output_mismatch(with_extras, written(subtitles: [], attachments: 1, chapters: 3), expected_audio_streams: 2))
        .to eq('output has 0 subtitle(s), source has 1')
    end

    it 'lets audio grow (--keep-original-audio)' do
      expect(described_class.output_mismatch(source, written(audio: two_tracks + [ProbeFixture.audio]), expected_audio_streams: 3)).to be_nil
    end

    it 'flags a silent downmix of the primary track' do
      surround = ProbeFixture.source('in.mkv', audio: [ProbeFixture.audio(codec: 'eac3', channels: 6, default: true)])
      stereo = ProbeFixture.source('out.mkv', audio: [ProbeFixture.audio(codec: 'eac3', channels: 2, default: true)])

      expect(described_class.output_mismatch(surround, stereo, expected_audio_streams: 1)).to match(/2 channels.*source has 6/)
    end

    it 'follows the primary track when it is not the first stream' do
      source = ProbeFixture.source('in.mkv', audio: [ProbeFixture.audio(language: 'spa'),
                                                     ProbeFixture.audio(channels: 6, language: 'eng', default: true)])
      output = ProbeFixture.source('out.mkv', audio: [ProbeFixture.audio(language: 'spa'),
                                                      ProbeFixture.audio(channels: 2, language: 'eng', default: true)])

      expect(described_class.output_mismatch(source, output, expected_audio_streams: 2)).to match(/2 channels.*source has 6/)
    end
  end

  describe 'owner on replace' do
    it 'asks for the original owner on the new file, and carries on when not permitted' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'a.mkv')
        source = File.join(dir, 'b.mkv')
        File.write(target, 'old')
        File.write(source, 'new')
        stat = File.stat(target)
        expect(File).to receive(:chown).with(stat.uid, stat.gid, source).and_raise(Errno::EPERM)

        described_class.atomic_replace(source, target)

        expect(File.read(target)).to eq('new')
      end
    end
  end
end
