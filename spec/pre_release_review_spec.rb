require 'spec_helper'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# One example per finding of docs/research/pre-release-review-2026-11.md. Each
# drives the real code over synthetic media and asserts what a user would see.
module ReviewFixtures
  DIR = Dir.mktmpdir('neutraliser-review-fixtures')
  at_exit { FileUtils.remove_entry(DIR) if Dir.exist?(DIR) }

  module_function

  def ffmpeg(*args)
    system('ffmpeg', '-hide_banner', '-v', 'error', '-y', *args) || raise("ffmpeg failed: #{args.join(' ')}")
  end

  # Video, two audio tracks, forced subtitle, chapters, font attachment, title.
  def rich
    File.join(DIR, 'rich.mkv').tap do |path|
      next if File.exist?(path)

      font = File.join(DIR, 'font.ttf')
      srt = File.join(DIR, 's.srt')
      meta = File.join(DIR, 'meta.txt')
      File.write(font, 'fake-font-bytes')
      File.write(srt, "1\n00:00:01,000 --> 00:00:02,000\nhello\n\n")
      File.write(meta, ";FFMETADATA1\ntitle=Fixture Film\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=3000\ntitle=One\n" \
                       "[CHAPTER]\nTIMEBASE=1/1000\nSTART=3000\nEND=6000\ntitle=Two\n")
      ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=6',
             '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6:sample_rate=48000',
             '-f', 'lavfi', '-i', 'sine=frequency=660:duration=6:sample_rate=48000',
             '-i', srt, '-i', meta,
             '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s', '-map_metadata', '4', '-map_chapters', '4',
             '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k', '-af', 'volume=-20dB', '-c:s', 'srt',
             '-metadata:s:a:0', 'language=eng', '-metadata:s:a:0', 'title=Main English',
             '-metadata:s:a:1', 'language=spa', '-metadata:s:a:1', 'title=Spanish Dub',
             '-metadata:s:s:0', 'language=eng', '-disposition:a:0', 'default+hearing_impaired', '-disposition:a:1', '0',
             '-disposition:s:0', 'forced',
             '-attach', font, '-metadata:s:t:0', 'mimetype=font/ttf', '-metadata:s:t:0', 'filename=font.ttf',
             path)
    end
  end

  def film(volume_db: -20, secs: 6, ext: 'mkv')
    File.join(DIR, "film#{volume_db}_#{secs}.#{ext}").tap do |path|
      next if File.exist?(path)

      ffmpeg('-f', 'lavfi', '-i', "testsrc=size=64x64:rate=5:duration=#{secs}",
             '-f', 'lavfi', '-i', "sine=frequency=440:duration=#{secs}:sample_rate=48000",
             '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k',
             '-af', "volume=#{volume_db}dB", path)
    end
  end

  # Loud-peaks-over-quiet-bed: far under target, with no headroom to reach it.
  def peaky
    File.join(DIR, 'peaky.mkv').tap do |path|
      next if File.exist?(path)

      ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1:d=120',
             '-f', 'lavfi', '-i', "aevalsrc='if(lt(mod(t\\,30)\\,0.002)\\,0.95\\,0.01)*sin(2*PI*1000*t)':s=48000:d=120",
             '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'flac', path)
    end
  end

  # About -25 LUFS overall, but the 30 s the quick sample reads sits at -20.
  def loud_middle
    File.join(DIR, 'loud_middle.mkv').tap do |path|
      next if File.exist?(path)

      ffmpeg('-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=1:d=120',
             '-f', 'lavfi', '-i', "aevalsrc='if(between(t\,44\,76)\,0.15\,0.035)*sin(2*PI*440*t)':s=48000:d=120",
             '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '96k', path)
    end
  end

  def silent
    File.join(DIR, 'silent.mkv').tap do |path|
      next if File.exist?(path)

      ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=6', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo:d=6',
             '-map', '0', '-map', '1', '-shortest', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-b:a', '128k', path)
    end
  end
end

RSpec.describe 'pre-release review', :real_ffmpeg do
  let(:dir) { Dir.mktmpdir }
  let(:logged) { [] }
  let(:bin) { File.expand_path('../bin/neutraliser', __dir__) }

  before do
    skip 'ffmpeg/ffprobe not available on PATH' unless system('which ffmpeg > /dev/null 2>&1') && system('which ffprobe > /dev/null 2>&1')
    allow(Neutraliser.logger).to receive(:log) { |message| logged << message }
  end

  after { FileUtils.remove_entry(dir) if Dir.exist?(dir) }

  def place(fixture, name = File.basename(fixture))
    File.join(dir, name).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(fixture, path)
    end
  end

  def run(path, **options)
    Neutraliser::Processor.new(fast_verify: false, **options).process(path)
  end

  def run_cli(*args, chdir: dir, env: {})
    out, status = Open3.capture2e(env, RbConfig.ruby, bin, *args, chdir: chdir)
    [out.scrub, status]
  end

  def profile_stamp(path) = Neutraliser::FFmpegWrapper.read_stamp(path)&.profile

  def probe(path, *args)
    out, = Open3.capture2e('ffprobe', '-v', 'error', *args, '-of', 'csv=p=0', path)
    out.strip
  end

  def integrated(path)
    out, = Open3.capture2e('ffmpeg', '-hide_banner', '-nostats', '-i', path, '-map', '0:a:0',
                           '-af', 'ebur128=framelog=quiet', '-f', 'null', '-')
    out[/I:\s+(-?[\d.]+) LUFS/, 1].to_f
  end

  def fake_ffmpeg(script)
    FileUtils.mkdir_p(File.join(dir, 'shim'))
    File.join(dir, 'shim', 'ffmpeg').tap do |path|
      File.write(path, script)
      File.chmod(0o755, path)
    end
  end

  describe 'security' do
    it 'runs no command from a .env in the working directory' do
      File.write(File.join(dir, '.env'), "NOPE=$(touch #{dir}/command-ran)\n")

      out, status = run_cli('version')

      expect(out).to match(/Neutraliser v/)
      expect(status).to be_success
      expect(File.exist?(File.join(dir, 'command-ran'))).to be false
    end

    it 'does not hand variables from a .env to ffmpeg' do
      place(ReviewFixtures.film)
      File.write(File.join(dir, '.env'), "FFREPORT=file=#{dir}/ffreport.log:level=16\n")

      run_cli('process', '--dry-run', 'film-20_6.mkv')

      expect(File.exist?(File.join(dir, 'ffreport.log'))).to be false
    end

    it 'reads only the Plex settings from .env, literally, for analyze-plex' do
      env_file = File.join(dir, '.env')
      File.write(env_file, %(export PLEX_TOKEN="abc123"\nPLEX_SERVER_URL=$(touch #{dir}/command-ran)\nLD_PRELOAD=/evil.so\n))
      saved = %w[PLEX_TOKEN PLEX_SERVER_URL LD_PRELOAD].to_h { |key| [key, ENV.delete(key)] }

      begin
        Neutraliser::PlexEnv.load(env_file)

        expect(ENV.fetch('PLEX_TOKEN')).to eq('abc123')
        expect(ENV.fetch('PLEX_SERVER_URL')).to eq("$(touch #{dir}/command-ran)")
        expect(ENV.key?('LD_PRELOAD')).to be false
        expect(File.exist?(File.join(dir, 'command-ran'))).to be false
      ensure
        saved.each { |key, value| ENV[key] = value }
      end
    end

    it 'keeps its staging directory private and refuses one owned by someone else' do
      staging = File.join(dir, 'staging')

      Neutraliser::LocalStager.new(enabled: true, staging_dir: staging)
      expect(File.stat(staging).mode & 0o777).to eq(0o700)

      allow(File).to receive(:owned?).and_call_original
      allow(File).to receive(:owned?).with(staging).and_return(false)
      expect { Neutraliser::LocalStager.new(enabled: true, staging_dir: staging) }.to raise_error(/not owned/)
    end
  end

  describe 'first-run' do
    it 'still runs when HOME is not writable, as under docker --user' do
      film = place(ReviewFixtures.film)
      home = File.join(dir, 'ro')
      FileUtils.mkdir_p(home)
      File.chmod(0o500, home)

      out, status = run_cli('process', '--dry-run', film, env: { 'HOME' => home })
      File.chmod(0o700, home)

      expect(out).to include('found=1')
      expect(status).to be_success
    end

    it 'scans a directory whose name has glob characters' do
      place(ReviewFixtures.film, 'Movies [HD] {x}/film.mkv')

      expect(run(File.join(dir, 'Movies [HD] {x}'), dry_run: true)[:found]).to eq(1)
    end

    it 'reports on a directory whose name has glob characters' do
      place(ReviewFixtures.film, 'Movies [HD]/film.mkv')

      expect(Neutraliser::Report.new(File.join(dir, 'Movies [HD]')).rows.length).to eq(1)
    end

    it 'counts and cleans caches under names with glob characters' do
      cache_dir = File.join(dir, 'TV [HD]')
      FileUtils.mkdir_p(cache_dir)
      video = File.join(cache_dir, 'Film [1080p].mkv')
      cache = File.join(cache_dir, 'Film [1080p].loudnorm_livingroom.json')
      File.write(video, 'x')
      File.write(cache, '{}')
      File.utime(Time.at(1_500_000_000), Time.at(1_500_000_000), cache)
      manager = Neutraliser::CacheManager.new

      expect(manager.cache_stats(cache_dir)[:count]).to eq(1)

      manager.cleanup_stale_cache(video)
      expect(File.exist?(cache)).to be false
    end

    it 'processes a relative name with a colon rather than reading it as an ffmpeg protocol' do
      place(ReviewFixtures.film, 'Alien: Covenant.mkv')

      out, status = run_cli('process', '--replace', 'Alien: Covenant.mkv')

      expect(out).to include('done=1')
      expect(status).to be_success
      expect(profile_stamp(File.join(dir, 'Alien: Covenant.mkv'))).to eq('livingroom')
    end

    it 'fails a file it cannot read instead of calling it a file with no audio' do
      broken = File.join(dir, 'broken.mkv')
      File.write(broken, 'this is not a video')

      summary = run(broken)

      expect(summary[:failed]).to eq(1)
      expect(summary[:failed_by_reason]).to eq(unreadable: 1)
    end

    it 'still skips a real file that has no audio' do
      video_only = File.join(dir, 'video_only.mkv')
      ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=2', '-c:v', 'libx264', '-preset', 'ultrafast', video_only)

      summary = run(video_only)

      expect(summary[:results].first[:reason]).to eq(:no_audio_track)
      expect(summary[:failed]).to eq(0)
    end

    it 'gives one clear error when ffmpeg is missing' do
      2.times { |i| place(ReviewFixtures.film, "lib/f#{i}.mkv") }

      out, status = run_cli('process', File.join(dir, 'lib'), env: { 'PATH' => '/nonexistent' })

      expect(status.exitstatus).to eq(1)
      expect(out).to match(/ffmpeg not found/i)
      expect(out.lines.length).to be <= 2
    end

    it 'warns that object audio cannot be detected on ffmpeg older than 7.1' do
      allow(Neutraliser::FFmpegWrapper).to receive(:version).and_return([6, 1])

      run(place(ReviewFixtures.film), dry_run: true)

      expect(logged.join("\n")).to match(/ffmpeg 6\.1.*Atmos/i)
    end

    it 'does not warn on ffmpeg 7.1 or a build with no version number' do
      [[7, 1], nil].each do |version|
        allow(Neutraliser::FFmpegWrapper).to receive(:version).and_return(version)
        run(place(ReviewFixtures.film), dry_run: true)
      end

      expect(logged.join("\n")).not_to match(/Atmos/i)
    end

    it 'skips a track named as Atmos when this ffmpeg has no way to check it' do
      film = File.join(dir, 'Movie.DDP5.1.Atmos.mkv')
      ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=4',
                            '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4:sample_rate=48000',
                            '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'eac3', film)
      allow(Neutraliser::FFmpegWrapper).to receive(:version).and_return([6, 1])

      summary = run(film, replace: true)

      expect(summary[:results].first[:reason]).to eq(:object_audio)
      expect(profile_stamp(film)).to be_nil
    end

    it 'reports a lock file it cannot open in one line' do
      film = place(ReviewFixtures.film)

      out, status = run_cli('process', '--dry-run', '--lock-file', '/nonexistent/dir/lock', film)

      expect(status.exitstatus).to eq(1)
      expect(out).to match(%r{lock file /nonexistent/dir/lock})
      expect(out).not_to match(/\.rb:\d+/)
    end
  end

  describe 'data safety' do
    it 'keeps attachments, chapters, subtitles, track tags and the container title on --replace' do
      film = place(ReviewFixtures.rich)

      run(film, replace: true)

      expect(profile_stamp(film)).to eq('livingroom')
      expect(probe(film, '-select_streams', 't', '-show_entries', 'stream_tags=filename')).to eq('font.ttf')
      expect(probe(film, '-select_streams', 't', '-show_entries', 'stream_tags=mimetype')).to eq('font/ttf')
      expect(probe(film, '-show_entries', 'chapter=id').lines.length).to eq(2)
      expect(probe(film, '-select_streams', 's', '-show_entries', 'stream_tags=language')).to eq('eng')
      expect(probe(film, '-select_streams', 'a:1', '-show_entries', 'stream_tags=title')).to eq('Spanish Dub')
      expect(probe(film, '-show_entries', 'format_tags=title')).to eq('Fixture Film')
    end

    it 'keeps every disposition flag on the normalised track' do
      film = place(ReviewFixtures.rich)

      run(film, replace: true)

      expect(probe(film, '-select_streams', 'a:0', '-show_entries', 'stream_disposition=default,hearing_impaired')).to eq('1,1')
      expect(probe(film, '-select_streams', 's:0', '-show_entries', 'stream_disposition=forced')).to eq('1')
    end

    it 'keeps attachments and adds one track with --keep-original-audio' do
      film = place(ReviewFixtures.rich)

      run(film, replace: true, keep_original_audio: true)

      expect(probe(film, '-select_streams', 'a', '-show_entries', 'stream=index').lines.length).to eq(3)
      expect(probe(film, '-select_streams', 't', '-show_entries', 'stream_tags=filename')).to eq('font.ttf')
    end

    describe 'MP4 metadata' do
      def itunes_atom?(path, atom) = File.binread(path).include?(atom.b)

      def tagged_mp4(*extra)
        File.join(dir, 'tagged.mp4').tap do |path|
          ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=4',
                                '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4:sample_rate=48000,volume=-15dB',
                                *extra, '-c:a', 'aac', path)
        end
      end

      it 'keeps cover art and iTunes atoms, recording the run in the sidecar instead' do
        cover = File.join(dir, 'cover.jpg')
        ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'color=c=red:s=100x100:d=1', '-frames:v', '1', cover)
        film = tagged_mp4('-i', cover, '-map', '0', '-map', '1', '-map', '2', '-c:v', 'libx264', '-preset', 'ultrafast',
                          '-c:v:1', 'mjpeg', '-disposition:v:1', 'attached_pic', '-metadata', 'show=My Show')

        first = run(film, replace: true)
        second = run(film, replace: true)

        expect(first[:done]).to eq(1)
        expect(probe(film, '-select_streams', 'v', '-show_entries', 'stream=codec_name').lines.length).to eq(2)
        expect(itunes_atom?(film, 'covr')).to be true
        expect(itunes_atom?(film, 'tvsh')).to be true
        expect(integrated(film)).to be_within(1.0).of(-20)
        expect(second[:results].first[:reason]).to eq(:already_processed)
      end

      it 'keeps iTunes atoms on a tagged file with no cover' do
        film = tagged_mp4('-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-metadata', 'show=My Show')

        run(film, replace: true)

        expect(itunes_atom?(film, 'tvsh')).to be true
        expect(probe(film, '-show_entries', 'format_tags=show')).to eq('My Show')
      end

      it 'still stamps an MP4 with nothing to lose' do
        film = tagged_mp4('-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast')

        run(film, replace: true)

        expect(profile_stamp(film)).to eq('livingroom')
      end
    end

    it 'does not overwrite a source that changed during the run' do
      film = place(ReviewFixtures.film)
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { File.open(film, 'ab') { |f| f.write('late bytes') } }
      end

      summary = run(film, replace: true)

      expect(summary[:failed_by_reason]).to eq(source_changed: 1)
      expect(File.binread(film)).to end_with('late bytes')
      expect(Dir.children(dir).grep(/_neutraliser_/)).to be_empty
    end

    it 'does not write a copy from a source that changed during the run' do
      film = place(ReviewFixtures.film)
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { File.open(film, 'ab') { |f| f.write('late bytes') } }
      end

      summary = run(film)

      expect(summary[:failed_by_reason]).to eq(source_changed: 1)
      expect(Dir.children(dir).grep(/_normalized/)).to be_empty
    end

    it 'replaces through a symlink at the real file, keeping the link' do
      real = place(ReviewFixtures.film, 'real/film.mkv')
      link_dir = File.join(dir, 'lib')
      FileUtils.mkdir_p(link_dir)
      link = File.join(link_dir, 'film.mkv')
      File.symlink(real, link)

      summary = run(link, replace: true)

      expect(summary[:done]).to eq(1)
      expect(File.symlink?(link)).to be true
      expect(profile_stamp(real)).to eq('livingroom')
      expect(Dir.children(File.dirname(real)).grep(/_neutraliser_/)).to be_empty
    end

    it 'replaces through a symlink with --local-stage too' do
      real = place(ReviewFixtures.film, 'real/film.mkv')
      link_dir = File.join(dir, 'lib')
      FileUtils.mkdir_p(link_dir)
      link = File.join(link_dir, 'film.mkv')
      File.symlink(real, link)
      stub_const('Neutraliser::LocalStager::STAGING_DIR', File.join(dir, 'staging'))

      run(link, replace: true, local_stage: true)

      expect(File.symlink?(link)).to be true
      expect(profile_stamp(real)).to eq('livingroom')
    end

    it 'keeps an earlier _normalized file when a copy-mode encode fails' do
      film = place(ReviewFixtures.film, 'film.mkv')
      earlier = File.join(dir, 'film_normalized.mkv')
      File.write(earlier, 'earlier output')
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization) do |_input, output, *_rest, **_kwargs|
        File.write(output, 'partial')
        raise Neutraliser::FFmpegError, 'boom'
      end

      summary = run(film)

      expect(summary[:failed]).to eq(1)
      expect(File.read(earlier)).to eq('earlier output')
    end

    it 'writes copy-mode output under a temporary name until it is verified' do
      film = place(ReviewFixtures.film, 'film.mkv')
      output_seen = nil
      allow(Neutraliser::FFmpegWrapper).to receive(:apply_normalization).and_wrap_original do |original, input, output, *rest, **kwargs|
        output_seen = File.basename(output)
        original.call(input, output, *rest, **kwargs)
      end

      run(film)

      expect(output_seen).not_to eq('film_normalized.mkv')
      expect(profile_stamp(File.join(dir, 'film_normalized.mkv'))).to eq('livingroom')
    end

    it 'hides temp output from media scanners, warns about leftovers and never treats one as a film' do
      expect(File.basename(Neutraliser::FileManager.safe_temp_path('/x/film.mkv'))).to match(/\A\.film_neutraliser_\h{16}\.mkv\z/)

      place(ReviewFixtures.film, 'lib/film.mkv')
      leftover = place(ReviewFixtures.film, 'lib/.film_neutraliser_0123456789abcdef.mkv')

      summary = run(File.join(dir, 'lib'), dry_run: true)

      expect(summary[:found]).to eq(1)
      expect(logged.join("\n")).to match(/leftover.*#{Regexp.escape(leftover)}/i)
      expect(File.exist?(leftover)).to be true
    end

    it 'does not process a _normalized copy as a film of its own' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      place(ReviewFixtures.film, 'lib/film_normalized.mkv')
      place(ReviewFixtures.film, 'lib/other_normalized.mkv')

      summary = run(File.join(dir, 'lib'), dry_run: true)

      expect(summary[:results].map { |r| File.basename(r[:file]) }).to contain_exactly('film.mkv', 'other_normalized.mkv')
    end

    it 'on SIGTERM stops ffmpeg, removes the temp output, exits 143 and leaves the original' do
      film = place(ReviewFixtures.film)
      original_bytes = File.binread(film)
      child_pid_file = File.join(dir, 'child.pid')
      fake_ffmpeg(<<~SH)
        #!/bin/sh
        if printf '%s' "$*" | grep -q NEUTRALISER_; then
          for a; do last=$a; done
          printf partial > "$last"
          echo $$ > #{child_pid_file}
          exec sleep 60
        fi
        exec #{`which ffmpeg`.strip} "$@"
      SH
      log = File.join(dir, 'out.log')
      pid = Process.spawn({ 'PATH' => "#{dir}/shim:#{ENV.fetch('PATH')}" }, RbConfig.ruby, bin, 'process', '--replace', film,
                          out: log, err: log, pgroup: true)
      started = Time.now
      sleep 0.05 until File.exist?(child_pid_file) || Time.now - started > 30
      sleep 0.2
      child = File.read(child_pid_file).to_i

      Process.kill('TERM', pid)
      stopped = Time.now
      _, status = Process.wait2(pid)

      expect(Time.now - stopped).to be < 8
      expect(status.exitstatus).to eq(143)
      expect { Process.kill(0, child) }.to raise_error(Errno::ESRCH)
      expect(File.binread(film)).to eq(original_bytes)
      expect(Dir.children(dir).grep(/_neutraliser_/)).to be_empty
      expect(File.read(log)).not_to match(/\.rb:\d+/)
    ensure
      begin
        Process.kill('KILL', pid) if pid
        Process.wait(pid) if pid
      rescue SystemCallError
        nil
      end
    end

    it 'names the variable that controls the operation that timed out, and stops the child' do
      pid_file = File.join(dir, 'pid')
      script = File.join(dir, 'slow.sh')
      File.write(script, "#!/bin/sh\necho $$ > #{pid_file}\nexec sleep 60\n")
      File.chmod(0o755, script)

      expect { Neutraliser::FFmpegWrapper.send(:execute_with_timeout, [script], 0.5, 'Normalization') }
        .to raise_error(Neutraliser::FFmpegTimeoutError, /NEUTRALISER_NORMALIZATION_TIMEOUT/)
      expect { Process.kill(0, File.read(pid_file).to_i) }.to raise_error(Errno::ESRCH)
    end

    describe 'output verification' do
      def mismatch(source, output, expected: 1, primary: nil)
        Neutraliser::FileManager.output_mismatch(source, output, expected_audio_streams: expected, primary: primary)
      end

      def audio(path, layout)
        ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=4',
                              '-f', 'lavfi', '-i', "sine=frequency=440:duration=4,aformat=channel_layouts=#{layout}",
                              '-map', '0', '-map', '1', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', path)
        path
      end

      it 'passes a faithful output' do
        film = place(ReviewFixtures.rich, 'a.mkv')
        copy = place(ReviewFixtures.rich, 'b.mkv')

        expect(mismatch(film, copy, expected: 2)).to be_nil
      end

      it 'catches a silent downmix of the primary track' do
        source = audio(File.join(dir, 'six.mkv'), '5.1')
        output = audio(File.join(dir, 'two.mkv'), 'stereo')
        primary = Neutraliser::FFmpegWrapper.detect_audio_tracks(source).first

        expect(mismatch(source, output, primary: primary)).to match(/2 channels.*source has 6/)
      end

      it 'catches a lost attachment' do
        source = place(ReviewFixtures.rich)
        output = File.join(dir, 'no_font.mkv')
        ReviewFixtures.ffmpeg('-i', source, '-map', '0:v', '-map', '0:a', '-map', '0:s', '-c', 'copy', output)

        expect(mismatch(source, output, expected: 2)).to match(/attachment/)
      end

      it 'catches a lost subtitle' do
        source = place(ReviewFixtures.rich)
        output = File.join(dir, 'no_subs.mkv')
        ReviewFixtures.ffmpeg('-i', source, '-map', '0:v', '-map', '0:a', '-map', '0:t', '-c', 'copy', output)

        expect(mismatch(source, output, expected: 2)).to match(/subtitle/)
      end

      it 'catches lost chapters' do
        source = place(ReviewFixtures.rich)
        output = File.join(dir, 'no_chapters.mkv')
        ReviewFixtures.ffmpeg('-i', source, '-map', '0', '-map_chapters', '-1', '-c', 'copy', output)

        expect(mismatch(source, output, expected: 2)).to match(/chapter/)
      end

      it 'catches a lost audio track even when track detection under-counted the source' do
        source = place(ReviewFixtures.rich)
        output = File.join(dir, 'one_track.mkv')
        ReviewFixtures.ffmpeg('-i', source, '-map', '0:v', '-map', '0:a:0', '-map', '0:s', '-map', '0:t', '-c', 'copy', output)

        expect(mismatch(source, output, expected: 1)).to match(/audio/)
      end
    end

    it 'corrects the stamp on the primary track when it is not the first audio track' do
      film = File.join(dir, 'second_default.mkv')
      ReviewFixtures.ffmpeg('-f', 'lavfi', '-i', 'testsrc=size=64x64:rate=5:duration=6',
                            '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6:sample_rate=48000',
                            '-f', 'lavfi', '-i', 'sine=frequency=660:duration=6:sample_rate=48000',
                            '-map', '0', '-map', '1', '-map', '2', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac',
                            '-af', 'volume=-20dB', '-disposition:a:0', '0', '-disposition:a:1', 'default', film)
      allow(Neutraliser::FFmpegWrapper).to receive(:predict_loudnorm_type).and_return('Dynamic')
      allow(Neutraliser::FFmpegWrapper).to receive(:parse_normalization_type).and_return('Linear')

      run(film, replace: true, allow_dynamic: true)

      expect(probe(film, '-select_streams', 'a:1', '-show_entries', 'stream_tags=NEUTRALISER_MODE')).to eq('linear')
      expect(Neutraliser::FFmpegWrapper.read_stamp(film).mode).to eq('linear')
    end
  end

  describe 'records' do
    it 'does not let a dry run stop a later --resume from normalising' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      run(lib, dry_run: true)
      summary = run(lib, replace: true, resume: true)

      expect(summary[:resumed]).to eq(0)
      expect(profile_stamp(File.join(lib, 'film.mkv'))).to eq('livingroom')
    end

    it 'treats an older manifest with a dry-run record as unfinished' do
      film = place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')
      File.write(File.join(lib, '.neutraliser-run-manifest.jsonl'),
                 %({"file":"#{File.realpath(film)}","status":"done","reason":"dry_run","profile":"livingroom","target_lufs":-20.0}\n))

      run(File.realpath(lib), replace: true, resume: true)

      expect(profile_stamp(film)).to eq('livingroom')
    end

    it 'writes no run manifest during a dry run' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      summary = run(lib, dry_run: true)

      expect(File.exist?(File.join(lib, '.neutraliser-run-manifest.jsonl'))).to be false
      expect(summary[:manifest_path]).to be_nil
    end

    it 'retries a low-disk skip on --resume' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      first = run(lib, replace: true, disk_guard: Neutraliser::DiskGuard.new(min_free: 2**60))
      second = run(lib, replace: true, resume: true)

      expect(first[:skipped]).to eq(1)
      expect(second[:resumed]).to eq(0)
      expect(profile_stamp(File.join(lib, 'film.mkv'))).to eq('livingroom')
    end

    it 'does not treat a finished file as final on --resume under a different profile' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      run(lib, replace: true)
      summary = run(lib, replace: true, resume: true, profile: 'reference')

      expect(summary[:resumed]).to eq(0)
      expect(profile_stamp(File.join(lib, 'film.mkv'))).to eq('reference')
    end

    it 'skips a finished file on --resume under the same options' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      run(lib, replace: true)

      expect(run(lib, replace: true, resume: true)[:resumed]).to eq(1)
    end

    it 'records each file in the manifest as it finishes, so an interrupted run keeps its progress' do
      place(ReviewFixtures.film, 'lib/a.mkv')
      place(ReviewFixtures.film, 'lib/b.mkv')
      lib = File.join(dir, 'lib')
      processor = Neutraliser::Processor.new(replace: true, fast_verify: false)
      allow(processor).to receive(:process_one).and_wrap_original do |original, file|
        raise Interrupt if file.end_with?('b.mkv')

        original.call(file)
      end

      expect { processor.process(lib) }.to raise_error(Interrupt)

      records = File.readlines(File.join(lib, '.neutraliser-run-manifest.jsonl')).map { |line| JSON.parse(line) }
      expect(records.select { |r| r['status'] == 'done' }.map { |r| File.basename(r['file']) }).to eq(['a.mkv'])
    end

    it 'normalises the original on --replace after an earlier copy-mode run' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')

      run(lib)
      run(lib, replace: true)

      expect(profile_stamp(File.join(lib, 'film.mkv'))).to eq('livingroom')
    end

    it 'does not redo a copy-mode run' do
      place(ReviewFixtures.film, 'lib/film.mkv')
      lib = File.join(dir, 'lib')
      copy = File.join(lib, 'film_normalized.mkv')

      run(lib)
      written = File.mtime(copy)
      summary = run(lib)

      expect(summary[:done]).to eq(0)
      expect(summary[:results].map { |r| r[:reason] }).to eq([:already_processed])
      expect(File.mtime(copy)).to eq(written)
    end

    it 'honours a second, different --target-level' do
      film = place(ReviewFixtures.film)

      run(film, replace: true, target_level: -18)
      run(film, replace: true, target_level: -24)

      expect(integrated(film)).to be_within(1.0).of(-24)
    end

    it 'keeps the rest of the chosen profile under --target-level' do
      processor = Neutraliser::Processor.new(profile: 'night', target_level: -14, fast: true)
      profile = processor.instance_variable_get(:@profile)

      expect(profile).to include(lufs: -14.0, lra: 10.0, dynamic: true)
    end

    it 'gives a later --limit-db run a file an earlier run skipped as peak-limited' do
      film = place(ReviewFixtures.peaky)

      first = run(film, replace: true)
      second = run(film, replace: true, limit_db: 12)

      expect(first[:results].first[:reason]).to eq(:peak_limited)
      expect(second[:results].first[:reason]).to eq(:normalized)
      expect(Neutraliser::FFmpegWrapper.read_stamp(film).mode).to eq('limited')
    end

    it 'does not re-measure a peak-limited file on a re-run with the same options' do
      film = place(ReviewFixtures.peaky)

      run(film, replace: true)
      allow(Neutraliser::FFmpegWrapper).to receive(:measure_loudness).and_call_original
      summary = run(film, replace: true)

      expect(summary[:results].first[:reason]).to eq(:peak_limited)
      expect(Neutraliser::FFmpegWrapper).not_to have_received(:measure_loudness)
    end

    it 'looks again at a within-tolerance file under a stricter --tolerance' do
      film = place(ReviewFixtures.film(volume_db: 1.0, secs: 20))

      first = run(film, replace: true, tolerance: 1.0)
      again = run(film, replace: true, tolerance: 1.0)
      stricter = run(film, replace: true, tolerance: 0.3)

      expect(first[:results].first[:reason]).to eq(:within_tolerance)
      expect(again[:results].first[:reason]).to eq(:already_processed)
      expect(stricter[:results].first[:reason]).to eq(:normalized)
    end

    it 'measures two files sharing a basename separately' do
      place(ReviewFixtures.film(volume_db: -30), 'lib/same.mkv')
      place(ReviewFixtures.film(volume_db: -10, ext: 'mp4'), 'lib/same.mp4')

      run(File.join(dir, 'lib'), dry_run: true)

      levels = logged.join("\n").scan(/Would normalize: (-[\d.]+) LUFS/).flatten.map(&:to_f)
      expect(levels.length).to eq(2)
      expect((levels[0] - levels[1]).abs).to be_within(1).of(20)
    end

    it 'does not reuse a measurement for a swapped file with an older mtime' do
      film = place(ReviewFixtures.film(volume_db: -30), 'film.mkv')
      run(film, dry_run: true)
      FileUtils.cp(ReviewFixtures.film(volume_db: -10, secs: 7), film)
      File.utime(Time.at(1_500_000_000), Time.at(1_500_000_000), film)

      logged.clear
      run(film, dry_run: true)

      expect(logged.join("\n")[/Would normalize: (-[\d.]+) LUFS/, 1].to_f).to be_within(1).of(-31.8)
    end

    it 'skips a silent track rather than re-encoding it with a made-up level' do
      film = place(ReviewFixtures.silent)
      bytes = File.binread(film)

      summary = run(film, replace: true)

      expect(summary[:results].first[:reason]).to eq(:silent)
      expect(File.binread(film)).to eq(bytes)
    end

    it 'does not trust a 30 second sample by default' do
      film = place(ReviewFixtures.loud_middle)

      Neutraliser::Processor.new(replace: true).process(film)

      expect(integrated(film)).to be_within(1.5).of(-20)
    end
  end

  describe 'per-file isolation' do
    it 'turns an exception in the skip check into that file failing, and carries on' do
      place(ReviewFixtures.film, 'lib/a.mkv')
      place(ReviewFixtures.film, 'lib/b.mkv')
      allow_any_instance_of(Neutraliser::SkipDecider).to receive(:already_processed?).and_wrap_original do |original, file, profile|
        raise ArgumentError, 'invalid byte sequence in UTF-8' if file.end_with?('a.mkv')

        original.call(file, profile)
      end

      summary = run(File.join(dir, 'lib'), replace: true)

      expect(summary[:done]).to eq(1)
      expect(summary[:failed_by_reason]).to eq(processing_error: 1)
    end

    it 'still ends the run on a disk-guard abort' do
      place(ReviewFixtures.film, 'lib/a.mkv')
      place(ReviewFixtures.film, 'lib/b.mkv')

      summary = run(File.join(dir, 'lib'), replace: true, disk_guard: Neutraliser::DiskGuard.new(abort_free: 2**60))

      expect(summary[:aborted]).to be true
      expect(summary[:results]).to be_empty
    end

    it 'processes a file whose name is not valid UTF-8, on a filesystem that allows one' do
      lib = File.join(dir, 'lib')
      FileUtils.mkdir_p(lib)
      begin
        FileUtils.cp(ReviewFixtures.film, File.join(lib, "caf\xE9.mkv"))
      rescue Errno::EILSEQ
        skip 'this filesystem refuses such names (APFS); covered on Linux'
      end

      first = run(lib, replace: true)
      second = run(lib, replace: true)

      expect(first[:done]).to eq(1)
      expect(second[:results].first[:reason]).to eq(:already_processed)
    end

    it 'keeps the sidecar usable when a file name is not valid UTF-8' do
      bad = File.join(dir, "caf\xE9.mkv")
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(bad).and_return(10)
      allow(File).to receive(:mtime).and_call_original
      allow(File).to receive(:mtime).with(bad).and_return(Time.at(1_700_000_000))
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(bad).and_return(true)
      profile = Neutraliser::Profiles.get_profile('livingroom')
      decider = Neutraliser::SkipDecider.new(dir, fast_verification: false)

      decider.mark_processed(bad, profile)

      expect(JSON.parse(File.read(File.join(dir, '.neutraliser'))).length).to eq(1)
      expect(Neutraliser::SkipDecider.new(dir, fast_verification: false).already_processed?(bad, profile)).to be true
    end

    it 'writes a manifest record for a file name that is not valid UTF-8' do
      manifest = File.join(dir, 'manifest.jsonl')
      processor = Neutraliser::Processor.new

      processor.send(:append_manifest_entry, manifest, file: "/m/caf\xE9.mkv", status: 'queued')

      expect(JSON.parse(File.read(manifest))['file']).to eq('/m/caf�.mkv')
    end

    it 'returns subprocess output as valid UTF-8 even when the media has stray bytes' do
      stdout, stderr, = Neutraliser::FFmpegWrapper.send(:execute_with_timeout, ['sh', '-c', 'printf "caf\351"; printf "caf\351" >&2'], 5, 'Probe')

      expect(stdout).to eq('caf�')
      expect(stderr).to eq('caf�')
    end
  end

  describe 'disk guard' do
    it 'reads free space when the device name has a space in it' do
      df = "Filesystem 1024-blocks Used Available Capacity Mounted on\n//nas/My Media 1000 400 600 40% /mnt/My Media\n"
      allow(Open3).to receive(:capture2).and_return([df, instance_double(Process::Status, success?: true)])

      expect(Neutraliser::DiskGuard.new(min_free: 1).free_bytes('/mnt/My Media')).to eq(600 * 1024)
    end
  end
end
