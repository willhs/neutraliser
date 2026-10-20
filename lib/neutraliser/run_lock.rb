module Neutraliser
  # One run at a time per lock file. An flock(2) lock belongs to the open file,
  # so the kernel drops it when the process dies: no stale lock to reclaim
  # after a killed run, and it works across containers sharing the lock file's
  # filesystem (a PID in a lock dir does not).
  class RunLock
    class Busy < StandardError; end

    def self.hold(path)
      file = File.open(path, File::RDWR | File::CREAT, 0o644)
      unless file.flock(File::LOCK_EX | File::LOCK_NB)
        owner = file.read.to_s.strip
        raise Busy, "another run holds #{path}#{" (pid #{owner})" unless owner.empty?}"
      end

      file.truncate(0)
      file.write(Process.pid.to_s)
      file.flush
      yield
    ensure
      file&.close
    end
  end
end
