require 'spec_helper'
require 'fileutils'

RSpec.describe Neutraliser::LocalStager do
  let(:staging_dir) { Dir.mktmpdir }
  let(:stager) { described_class.new(staging_dir: staging_dir) }
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
end
