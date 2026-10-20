require 'spec_helper'
require 'tmpdir'

RSpec.describe Neutraliser::RunLock do
  let!(:lock_path) { File.join(Dir.mktmpdir, 'run.lock') }

  it 'runs the block and records the owner pid' do
    seen = nil
    described_class.hold(lock_path) { seen = File.read(lock_path) }
    expect(seen).to eq(Process.pid.to_s)
  end

  it 'refuses a second holder, naming the first' do
    described_class.hold(lock_path) do
      expect { described_class.hold(lock_path) { raise 'should not run' } }
        .to raise_error(described_class::Busy, /pid #{Process.pid}/)
    end
  end

  it 'is free again after the holder exits, even by exception' do
    expect { described_class.hold(lock_path) { raise 'boom' } }.to raise_error('boom')
    ran = false
    described_class.hold(lock_path) { ran = true }
    expect(ran).to be(true)
  end

  it 'is released when the holding process dies without cleaning up' do
    ready_r, ready_w = IO.pipe
    pid = fork do
      ready_r.close
      held = File.open(lock_path, File::RDWR | File::CREAT)
      held.flock(File::LOCK_EX)
      ready_w.puts 'locked'
      sleep
    end
    ready_w.close
    begin
      ready_r.gets
      expect { described_class.hold(lock_path) { nil } }.to raise_error(described_class::Busy)
    ensure
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
    expect { described_class.hold(lock_path) { nil } }.not_to raise_error
  end
end
