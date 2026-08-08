require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::LocalStager do
  let(:staging_dir) { Dir.mktmpdir }
  let(:stager) { described_class.new(enabled: true, staging_dir: staging_dir) }
  let(:source_dir) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(staging_dir) if Dir.exist?(staging_dir)
    FileUtils.remove_entry(source_dir) if Dir.exist?(source_dir)
  end

  describe '#stage_in' do
    it 'copies file to staging directory and returns local path' do
      source = File.join(source_dir, 'movie.mp4')
      File.write(source, 'video content')

      local_path = stager.stage_in(source)

      expect(local_path).to start_with(staging_dir)
      expect(File.exist?(local_path)).to be true
      expect(File.read(local_path)).to eq('video content')
    end

    it 'preserves file extension' do
      source = File.join(source_dir, 'movie.mkv')
      File.write(source, 'x')

      local_path = stager.stage_in(source)

      expect(File.extname(local_path)).to eq('.mkv')
    end

    it 'generates unique paths to avoid collisions' do
      source = File.join(source_dir, 'movie.mp4')
      File.write(source, 'x')

      path_a = stager.stage_in(source)
      path_b = stager.stage_in(source)

      expect(path_a).not_to eq(path_b)
    end
  end

  describe '#stage_out' do
    it 'copies local file to remote destination' do
      local = File.join(staging_dir, 'output.mp4')
      File.write(local, 'processed')
      dest = File.join(source_dir, 'output.mp4')

      stager.stage_out(local, dest)

      expect(File.read(dest)).to eq('processed')
    end
  end

  describe '#cleanup' do
    it 'removes the staged file' do
      local = File.join(staging_dir, 'temp.mp4')
      File.write(local, 'x')

      stager.cleanup(local)

      expect(File.exist?(local)).to be false
    end

    it 'does not raise if file already gone' do
      expect { stager.cleanup('/tmp/nonexistent_file') }.not_to raise_error
    end
  end

  describe '#with_working_copy' do
    context 'when staging is enabled' do
      it 'stages the file in, yields the local path, and cleans up afterwards' do
        source = File.join(source_dir, 'movie.mp4')
        File.write(source, 'video content')

        yielded_path = nil
        stager.with_working_copy(source) do |working_path|
          yielded_path = working_path
          expect(working_path).to start_with(staging_dir)
          expect(File.exist?(working_path)).to be true
        end

        expect(File.exist?(yielded_path)).to be false
      end

      it 'cleans up the staged copy even when the block raises' do
        source = File.join(source_dir, 'movie.mp4')
        File.write(source, 'video content')

        yielded_path = nil
        expect do
          stager.with_working_copy(source) do |working_path|
            yielded_path = working_path
            raise 'boom'
          end
        end.to raise_error('boom')

        expect(File.exist?(yielded_path)).to be false
      end

      it 'does not attempt cleanup if staging in itself fails' do
        missing_source = File.join(source_dir, 'missing.mp4')

        expect do
          stager.with_working_copy(missing_source) { |working_path| working_path }
        end.to raise_error(Errno::ENOENT)
      end
    end

    context 'when staging is disabled' do
      let(:stager) { described_class.new(enabled: false, staging_dir: staging_dir) }

      it 'yields the original path unchanged and does not clean it up' do
        source = File.join(source_dir, 'movie.mp4')
        File.write(source, 'video content')

        yielded_path = nil
        stager.with_working_copy(source) { |working_path| yielded_path = working_path }

        expect(yielded_path).to eq(source)
        expect(File.exist?(source)).to be true
      end
    end
  end

  describe '#commit' do
    let(:output) { File.join(staging_dir, 'output.mp4') }

    before { File.write(output, 'normalized') }

    context 'when replace is true and staging is enabled' do
      it 'stages the output out to the destination and cleans up the local copy' do
        destination = File.join(source_dir, 'original.mp4')
        File.write(destination, 'original')

        stager.commit(output, destination, replace: true)

        expect(File.read(destination)).to eq('normalized')
        expect(File.exist?(output)).to be false
      end
    end

    context 'when replace is true and staging is disabled' do
      let(:stager) { described_class.new(enabled: false, staging_dir: staging_dir) }

      it 'atomically replaces the destination with the output' do
        destination = File.join(source_dir, 'original.mp4')
        File.write(destination, 'original')

        stager.commit(output, destination, replace: true)

        expect(File.read(destination)).to eq('normalized')
      end
    end

    context 'when replace is false and staging is enabled' do
      it 'stages the output out to the copy destination and cleans up the local copy' do
        destination = File.join(source_dir, 'original_normalized.mp4')

        stager.commit(output, destination, replace: false)

        expect(File.read(destination)).to eq('normalized')
        expect(File.exist?(output)).to be false
      end
    end

    context 'when replace is false and staging is disabled' do
      let(:stager) { described_class.new(enabled: false, staging_dir: staging_dir) }

      it 'does nothing - the output was already written directly to the destination' do
        destination = output

        expect { stager.commit(output, destination, replace: false) }.not_to raise_error
        expect(File.read(output)).to eq('normalized')
      end
    end
  end
end
