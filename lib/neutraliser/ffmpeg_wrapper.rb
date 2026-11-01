require 'open3'
require 'json'
require 'tmpdir'
require_relative 'ffmpeg_error'

module Neutraliser

  class FFmpegWrapper
    # Timeout constants (in seconds).
    #
    # Analysis and normalization both decode the file's entire audio stream, so
    # they get the same budget — analysis is if anything the cheaper of the two,
    # since it doesn't encode. Analysis previously had 300s against
    # normalization's 1800s, which meant any file too big to *measure* in five
    # minutes failed before it ever got the half hour allowed to process it. On
    # a NAS over SMB that is an ordinary HD episode, not a broken one: a 491MB
    # file measured in 162s on a gigabit mount, so anything past roughly 900MB
    # timed out.
    #
    # Override for slower mounts or larger files:
    #   NEUTRALISER_ANALYSIS_TIMEOUT=3600 neutraliser process /media/tv
    def self.env_timeout(name, default)
      raw = ENV.fetch("NEUTRALISER_#{name}_TIMEOUT", nil)
      value = raw.to_i
      value.positive? ? value : default
    end

    private_class_method :env_timeout

    ANALYSIS_TIMEOUT = env_timeout('ANALYSIS', 1800)
    QUICK_TIMEOUT = env_timeout('QUICK', 120)
    NORMALIZATION_TIMEOUT = env_timeout('NORMALIZATION', 1800)
    PROBE_TIMEOUT = env_timeout('PROBE', 30)

    # Containers that keep custom tags only at container level, and only
    # with -movflags +use_metadata_tags.
    MP4_FAMILY = %w[.mp4 .m4v .mov].freeze

    # Container tags the muxer writes itself, which say nothing about the film.
    MP4_TECHNICAL_TAGS = %w[major_brand minor_version compatible_brands encoder creation_time].freeze

    # Seconds a subprocess gets to exit after SIGTERM before it is killed.
    STOP_GRACE_S = 2

    # input_args are inserted before -i (e.g. ["-headers", "X-Plex-Token: ...\r\n"]
    # for authenticating a remote stream). That keeps the credential out of the
    # URL, and so out of ffmpeg's logs, but it is still in argv and visible to
    # `ps` for the length of the run: ffmpeg has no other way to take a header.
    # duration, when given, caps how much of the input is read (-t) — useful
    # for a fast preview measurement of a remote stream rather than a full
    # pass.
    # pre_filter runs ahead of loudnorm, so the measurement is of the signal as the
    # filter leaves it (--lra-target measures each compression candidate this way).
    # start_offset seeks before decoding (input-side -ss). Callers that measure
    # only a slice of a long file should use it: a film's opening minute is
    # logos and titles and reads several LU quieter than the film itself, so a
    # slice taken from the start systematically under-reports loudness.
    def self.measure_loudness(input_path, target_i: -20.0, target_tp: -1.5, target_lra: 12.0, input_args: [],
                              duration: nil, start_offset: nil, audio_index: 0, pre_filter: nil)
      cmd = ['ffmpeg', '-hide_banner', '-nostats', *DolbyStream::DRC_OFF, *input_args]
      cmd += ['-ss', start_offset.round.to_s] if start_offset&.positive?
      cmd += ['-i', input_path]
      cmd += ['-t', duration.to_s] if duration
      cmd += [
        '-map', "0:a:#{audio_index}",
        '-af', [pre_filter, "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{loudnorm_lra(target_lra)}:print_format=json"].compact.join(','),
        '-f', 'null', '-'
      ]

      _, stderr, status = execute_with_timeout(cmd, ANALYSIS_TIMEOUT, 'Loudness measurement')
      raise FFmpegError.from_run('Measurement', stderr, status) unless status.success?

      Measurement.from_loudnorm_json(parse_loudnorm_json(stderr))
    end

    # [major, minor] of the installed ffmpeg, or nil for a build with no release
    # number (a git snapshot). Raises FFmpegNotFoundError when ffmpeg or ffprobe
    # isn't on PATH, so a run can say so once, up front.
    def self.version
      output = %w[ffmpeg ffprobe].map do |tool|
        Open3.capture2e(tool, '-version').first
      rescue Errno::ENOENT
        raise FFmpegNotFoundError, "#{tool} not found on PATH. Install FFmpeg (brew install ffmpeg, apt install ffmpeg) " \
                                   'or use the Docker image.'
      end.first

      match = output.scrub.match(/\Affmpeg version n?(\d+)\.(\d+)/)
      match && [match[1].to_i, match[2].to_i]
    end

    # ffmpeg 5.1 is where loudnorm's LRA ceiling went from 20 to 50 (the
    # `reference` profile asks for 50) and alimiter gained `latency` (--limit-db).
    # Older builds reject both filter arguments outright.
    WIDE_FILTER_OPTIONS_FFMPEG = [5, 1].freeze
    LEGACY_LOUDNORM_MAX_LRA = 20.0

    # A build with no release number (a git snapshot) is assumed to be recent.
    def self.wide_filter_options?
      version = self.version
      version.nil? || (version <=> WIDE_FILTER_OPTIONS_FFMPEG) >= 0
    end

    # The LRA to hand loudnorm: the profile's own, held to what this ffmpeg
    # accepts. Constant gain never reads it (the measurement is the same at any
    # target), so only --allow-dynamic's loudnorm pass gets a tighter target.
    def self.loudnorm_lra(lra)
      wide_filter_options? ? lra : [lra, LEGACY_LOUDNORM_MAX_LRA].min
    end

    # The one ffprobe run a file gets: every stream, the container and the chapters, as JSON, plus the
    # stderr of a `-v info` run (which names subtitle codec ids ffmpeg has no decoder for). Returns
    # [stdout, stderr]. Timeboxed like every other subprocess call here. Raises FFmpegError when ffprobe
    # reports failure (a corrupt or truncated container, a file still being written), FFmpegTimeoutError
    # if it hangs, and Errno::ENOENT if ffprobe isn't installed: each distinct from "the media is
    # fine". Callers go through Source, which keeps the answer.
    def self.probe_file(input_path)
      cmd = [
        'ffprobe', '-hide_banner', '-v', 'info', '-show_streams', '-show_format', '-show_chapters',
        '-of', 'json', input_path
      ]
      stdout, stderr, status = execute_with_timeout(cmd, PROBE_TIMEOUT, 'File probe')
      raise FFmpegError.from_run('File probe', stderr, status) unless status.success?

      [stdout, stderr]
    end

    # Second opinion on an audio track's profile, from a slice cut out of the
    # middle of the file. libavcodec sets object-audio profiles (Atmos, DTS:X)
    # in the decoder, so a plain probe only sees what it decoded from the
    # file's opening frames. Stream-copying a mid-file slice into a scratch
    # .mka and probing that decodes different frames. Returns the profile name,
    # or nil if there is none or the probe fails (best effort, like
    # quick_loudness_sample).
    def self.probe_audio_profile_mid_file(source, seconds: 10)
      input_path = source.path
      track = source.primary_track
      start = (source.duration || 0) / 2
      Dir.mktmpdir('neutraliser-profile') do |dir|
        slice = File.join(dir, 'slice.mka')
        cmd = [
          'ffmpeg', '-hide_banner', '-nostats', '-v', 'error', '-y',
          '-ss', start.round.to_s, '-i', input_path,
          '-map', "0:a:#{track[:index]}", '-c', 'copy', '-t', seconds.to_s, slice
        ]
        _, _, status = execute_with_timeout(cmd, QUICK_TIMEOUT, 'Profile slice')
        return nil unless status.success?

        cmd = [
          'ffprobe', '-v', 'error', '-select_streams', 'a:0',
          '-show_entries', 'stream=profile', '-of', 'default=nw=1:nk=1', slice
        ]
        stdout, _, status = execute_with_timeout(cmd, PROBE_TIMEOUT, 'Profile probe')
        status.success? ? Source.profile_name(stdout.strip) : nil
      end
    rescue StandardError
      nil
    end

    def self.quick_loudness_sample(source, duration: 30, target_i: -20.0)
      # Quick LUFS estimation using a sample from the middle of the file
      # Much faster than analyzing the entire file

      input_path = source.path
      audio_index = source.primary_track[:index]
      total_duration = source.duration
      return nil unless total_duration
      return nil if total_duration < duration * 2 # File too short for meaningful sample

      # Start sampling from middle of file
      start_time = (total_duration - duration) / 2

      cmd = [
        'ffmpeg', '-hide_banner', '-nostats', *DolbyStream::DRC_OFF,
        '-ss', start_time.to_s, '-i', input_path,
        '-t', duration.to_s,
        '-map', "0:a:#{audio_index}",
        '-af', "loudnorm=I=#{target_i}:print_format=json",
        '-f', 'null', '-'
      ]

      _, stderr, status = execute_with_timeout(cmd, QUICK_TIMEOUT, 'Quick loudness sample')
      return nil unless status.success?

      Measurement.from_loudnorm_json(parse_loudnorm_json(stderr))
    rescue StandardError
      # A quick sample is a best-effort optimisation, not a required step —
      # any failure here (parse error, unexpected ffmpeg behaviour, etc.)
      # just falls back to the full analysis pass. FFmpegTimeoutError,
      # which subclasses StandardError via FFmpegError, is deliberately
      # included: a slow/hung quick sample should not block processing.
      nil
    end

    # The container the output is really written in. A release can be MP4
    # bytes named .mkv (Lost S01 "MULTi"); trusting the extension then picks
    # the wrong codec table and muxes mov_text subtitles into Matroska, which
    # fails. Only the MP4 family is sniffed: it is the one the extension has
    # been seen to lie about.
    def self.output_container(source, output_path)
      ext = File.extname(output_path).downcase
      return ext if MP4_FAMILY.include?(ext)

      source.mp4_family? ? '.mp4' : ext
    end

    # What the primary track is re-encoded to, with the source's dialnorm carried across.
    def self.decide_codec(source, output_path)
      track = source.primary_track
      choice = CodecChoice.decide(track, output_container(source, output_path),
                                  sample: ->(t) { estimate_bitrate_from_packets(source.path, "a:#{t[:index]}") })
      carry_dialnorm(choice, source.path, track)
    end

    def self.remux_plan(source, output_path, filter, codec_decision, stamp, keep_original:)
      container = output_container(source, output_path)
      RemuxPlan.new(source, output_path, container: container, mdta: mp4_mdta_safe?(source, container), filter: filter,
                                         codec_decision: codec_decision, stamp: stamp, keep_original: keep_original)
    end

    def self.apply_normalization(source, output_path, measured_data, profile, allow_dynamic: false,
                                 keep_original: false, limit_db: 0.0, compression: nil)
      primary_track = source.primary_track
      codec_decision = decide_codec(source, output_path)

      # A CompressionPlan (--lra-target) wraps the GainPlan for the compressed signal.
      plan = compression || (GainPlan.for(measured_data, profile, limit_db: limit_db) unless allow_dynamic)
      audio_filter = build_audio_filter(measured_data, profile, primary_track[:sample_rate], plan: plan)
      forced_mode = plan&.mode

      # Tags go into the same encode, so loudnorm's Linear/Dynamic choice has
      # to be predicted up front; its summary afterwards is the truth.
      predicted_mode = forced_mode || predict_mode(measured_data, profile)
      prior = source.stamp&.history
      stamp_for = lambda do |mode|
        gain = if plan
                 plan.applied
               elsif mode == Mode::LINEAR
                 profile[:lufs] - measured_data.input_i
               end
        build_stamp(profile, mode, codec_decision, gain: gain, measured: measured_data, compression: compression, prior: prior)
      end
      remux = remux_plan(source, output_path, audio_filter, codec_decision, stamp_for.call(predicted_mode),
                         keep_original: keep_original)

      ffmpeg_output = execute_with_progress(remux.argv)
      mode = forced_mode || parse_mode(ffmpeg_output) || Mode::UNKNOWN
      # Rare: loudnorm disagreed with the prediction. A stream-copy remux
      # corrects the record rather than leave a tag that lies.
      if [Mode::LINEAR, Mode::DYNAMIC].include?(mode) && mode != predicted_mode
        restamp(output_path, stamp_for.call(mode), remux.container, remux.layout.normalised.index, mdta: remux.mdta)
      end

      codec_decision = codec_decision.merge(mode: mode)
      return codec_decision unless forced_mode

      plan.shortfall.positive? ? codec_decision.merge(shortfall_lu: plan.shortfall) : codec_decision
    end

    def self.apply_normalization_single_pass(source, output_path, profile, keep_original: false)
      primary_track = source.primary_track
      codec_decision = decide_codec(source, output_path)

      loudnorm_filter = "loudnorm=I=#{profile[:lufs]}:TP=#{profile[:tp]}:LRA=#{loudnorm_lra(profile[:lra])}:print_format=summary"
      loudnorm_filter += ",#{pin_sample_rate(primary_track[:sample_rate])}" if primary_track[:sample_rate]

      # Single-pass loudnorm has no prior measurement pass, so it always
      # behaves as dynamic (per-frame) normalization regardless of the
      # filter's default linear setting.
      stamp = build_stamp(profile, Mode::DYNAMIC, codec_decision, gain: nil, measured: nil, prior: source.stamp&.history)
      remux = remux_plan(source, output_path, loudnorm_filter, codec_decision, stamp, keep_original: keep_original)

      ffmpeg_output = execute_with_progress(remux.argv)
      codec_decision.merge(mode: parse_mode(ffmpeg_output) || Mode::DYNAMIC)
    end

    # NOTE: `private` here has no effect on `def self.foo` methods (Ruby
    # only makes it private on instances of the *next* class body it
    # applies to, not the singleton class) — it was a no-op silently
    # leaving every method below public. Real privacy is enforced via
    # `private_class_method` at the bottom of the class instead.

    def self.execute_with_timeout(cmd, timeout_seconds, operation_name)
      # Use Open3.popen3 with manual timeout to avoid thread corruption from Timeout.timeout
      stdout_str = +''
      stderr_str = +''
      status = nil

      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        # Use IO.select with timeout to safely handle slow operations
        start_time = Time.now
        stdout_eof = false
        stderr_eof = false

        until stdout_eof && stderr_eof
          elapsed = Time.now - start_time
          if elapsed > timeout_seconds
            # Don't guess at corruption. The overwhelmingly common cause is a
            # large file on a slow or contended mount, and telling someone
            # their media is broken when it isn't sends them chasing ghosts.
            raise FFmpegTimeoutError,
                  "#{operation_name} timed out after #{timeout_seconds}s. Large files on network mounts " \
                  '(or several jobs running at once) can legitimately need longer — raise the limit with ' \
                  "#{timeout_variable(operation_name)}=<seconds>. If it times out with a generous limit and the " \
                  'file plays elsewhere, then suspect the file itself.'
          end

          # Check which streams have data available (with 1 second timeout per iteration)
          ready = IO.select([stdout, stderr].compact, nil, nil, 1)
          next unless ready

          ready[0].each do |io|
            if io == stdout
              data = io.read_nonblock(4096)
              stdout_str << data
            elsif io == stderr
              data = io.read_nonblock(4096)
              stderr_str << data
            end
          rescue IO::WaitReadable
            # Nothing to read right now
          rescue EOFError
            stdout_eof = true if io == stdout
            stderr_eof = true if io == stderr
          end
        end

        status = wait_thr.value
      ensure
        # On a timeout, and on a signal or any other exception raised in this
        # block. Open3 would otherwise wait for the child, and ffmpeg ignores
        # SIGPIPE, so it would finish its encode while `docker stop` ran out of
        # patience and killed us, orphaning the temp output.
        stop_process(wait_thr)
      end

      # Media tags and file names can hold any bytes. Everything downstream
      # (JSON.parse, regexes, manifest entries) needs valid UTF-8.
      [valid_utf8(stdout_str), valid_utf8(stderr_str), status]
    end

    def self.stop_process(wait_thr)
      return unless wait_thr.alive?

      Process.kill('TERM', wait_thr.pid)
      return if wait_thr.join(STOP_GRACE_S)

      Process.kill('KILL', wait_thr.pid)
      wait_thr.join
    rescue Errno::ESRCH
      nil
    end

    def self.valid_utf8(bytes)
      bytes.force_encoding(Encoding::UTF_8).scrub
    end

    def self.timeout_variable(operation_name)
      case operation_name
      when 'Loudness measurement' then 'NEUTRALISER_ANALYSIS_TIMEOUT'
      when 'Normalization', 'Restamp' then 'NEUTRALISER_NORMALIZATION_TIMEOUT'
      when 'Quick loudness sample', 'Profile slice' then 'NEUTRALISER_QUICK_TIMEOUT'
      else 'NEUTRALISER_PROBE_TIMEOUT'
      end
    end

    def self.parse_loudnorm_json(stderr_output)
      json_text = stderr_output[/\{\s*"input_i".*?\}/m]
      raise FFmpegError, 'loudnorm JSON not found in output' unless json_text

      JSON.parse(json_text)
    rescue JSON::ParserError => e
      raise FFmpegError, "Failed to parse loudnorm JSON: #{e.message}"
    end

    # Samples packet sizes over a short window for a stream ffprobe gave no bit_rate (common for MKV).
    # nil when it yields no usable number, so the codec choice falls through to the quality floor.
    def self.estimate_bitrate_from_packets(input_path, stream_spec, sample_seconds: 10)
      cmd = [
        'ffprobe', '-v', 'error', '-select_streams', stream_spec,
        '-show_entries', 'packet=size',
        '-read_intervals', "%+#{sample_seconds}",
        '-of', 'csv=p=0', input_path
      ]

      stdout, _stderr, status = execute_with_timeout(cmd, PROBE_TIMEOUT, 'Packet bitrate sampling')
      return nil unless status.success?

      sizes = stdout.each_line.map(&:strip).reject(&:empty?).map(&:to_i)
      return nil if sizes.empty?

      total_bytes = sizes.sum
      ((total_bytes * 8) / sample_seconds.to_f).round
    rescue StandardError
      nil
    end

    # The Dolby encoders write dialnorm -31 unless told otherwise, which would strip a source's
    # attenuation (see DolbyStream). Adds the source's own value to the decision when both ends are
    # Dolby; a track that holds none gets the encoder's default.
    def self.carry_dialnorm(codec_decision, input_path, track)
      return codec_decision unless DolbyStream.dolby_codec?(track[:codec]) && DolbyStream.dolby_encoder?(codec_decision[:encoder])

      dialnorm = source_dialnorm(input_path, track)
      dialnorm ? codec_decision.merge(dialnorm: dialnorm) : codec_decision
    end

    # The track's dialnorm in dB for the re-encode, or nil (logged) when its frames hold none. A read that
    # failed says nothing about the track, so it raises: the file fails, is left alone and is tried again
    # next run, where carrying on would write -31 over the source's value for good.
    def self.source_dialnorm(input_path, track)
      read_dialnorm(input_path, track)
    rescue NoDialnormError => e
      Neutraliser.logger.log "  Source has no dialnorm to carry (#{e.message.lines.first&.strip}); the output gets the encoder's -31"
      nil
    end

    # The track's dialnorm in dB, read from its first few frames stream-copied to a raw file (ffprobe
    # doesn't report it). Raises FFmpegError when they can't be read, NoDialnormError when they hold none.
    def self.read_dialnorm(input_path, track)
      format = DolbyStream.raw_format(track[:codec])
      Dir.mktmpdir('neutraliser-dialnorm') do |dir|
        raw = File.join(dir, "head.#{format}")
        cmd = ['ffmpeg', '-hide_banner', '-nostats', '-v', 'error', '-y', '-i', input_path, '-map', "0:a:#{track[:index]}",
               '-c', 'copy', '-frames:a', DIALNORM_PROBE_FRAMES.to_s, '-f', format, raw]
        _, stderr, status = execute_with_timeout(cmd, QUICK_TIMEOUT, 'Dialnorm read')
        raise FFmpegError.from_run('Dialnorm read', stderr, status) unless status.success?

        DolbyStream.dialnorm(File.binread(raw)) || raise(NoDialnormError, 'no dialnorm in the first frames')
      end
    end
    DIALNORM_PROBE_FRAMES = 8

    def self.build_loudnorm_filter(measured, target_i, target_tp, target_lra)
      "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{loudnorm_lra(target_lra)}" \
        ":measured_I=#{measured.input_i}" \
        ":measured_TP=#{measured.input_tp}" \
        ":measured_LRA=#{measured.input_lra}" \
        ":measured_thresh=#{measured.input_thresh}" \
        ":offset=#{measured.target_offset}" \
        ':linear=true:print_format=summary'
    end

    # Builds the audio filter chain to apply during the normalization pass:
    # the plan's constant-gain filter (plus limiter when it needs one), or
    # loudnorm when the caller opted into dynamic (no plan). A plan can never
    # engage dynamic compression the way loudnorm's linear mode can fall back
    # to; quiet-but-peaky sources land shy of target instead of being squashed.
    def self.build_audio_filter(measured, profile, source_sample_rate, plan:)
      filter = plan ? plan.filter : build_loudnorm_filter(measured, profile[:lufs], profile[:tp], profile[:lra])
      filter += ",#{plan ? "aresample=#{source_sample_rate}" : pin_sample_rate(source_sample_rate)}" if source_sample_rate
      filter
    end

    # Pins loudnorm's 192kHz output back to the source rate. After loudnorm,
    # ffmpeg 4.2 can't negotiate a channel layout through a bare aresample
    # ("Cannot select channel layout for the link"); aformat can, and still
    # inserts the resampler. Found by the ffmpeg 4.2 CI job.
    def self.pin_sample_rate(rate)
      "aformat=sample_rates=#{rate}"
    end

    # loudnorm's own linear-mode rule (af_loudnorm.c init): valid measured
    # values, the gain fits under the true-peak ceiling, and the source LRA
    # is within the target LRA. Anything else goes dynamic.
    def self.predict_mode(measured, profile)
      valid = measured.input_tp != 99 && measured.input_thresh != -70 &&
              measured.input_lra != 0 && measured.input_i != 0
      gain = profile[:lufs] - measured.input_i
      fits = measured.input_tp + gain <= profile[:tp] && measured.input_lra <= loudnorm_lra(profile[:lra])
      valid && fits ? Mode::LINEAR : Mode::DYNAMIC
    end

    def self.build_stamp(profile, mode, codec_decision, gain:, measured:, compression: nil, prior: nil)
      Stamp.now(
        profile: profile[:name], mode: mode.to_s, gain_db: gain, prior: prior,
        source_codec: codec_decision[:source_codec], source_dialnorm: codec_decision[:dialnorm],
        source_profile: codec_decision[:source_profile],
        source_bitrate: codec_decision[:source_bitrate].to_i.positive? ? codec_decision[:source_bitrate] : nil,
        measured_i: measured&.input_i, measured_tp: measured&.input_tp, measured_lra: measured&.input_lra,
        **(compression ? compression.stamp_fields : {})
      )
    end

    # use_metadata_tags is the only way to get a custom tag into an MP4, but it
    # writes every tag as an mdta key instead of iTunes' ilst atoms, and cover art
    # lives only in ilst. So on a file with a cover or descriptive tags, the
    # stamp would cost the cover and hide the tags from anything reading iTunes
    # atoms. Least lossy wins: those files keep their atoms and the sidecar holds
    # their record, as for AVI. A file already stamped this way has no atoms left
    # to lose.
    def self.mp4_mdta_safe?(source, container)
      return true unless MP4_FAMILY.include?(container)
      return false if source.attached_picture?

      tags = source.container_tag_names
      tags.any? { |tag| tag.start_with?('neutraliser_') } || (tags - MP4_TECHNICAL_TAGS).empty?
    end

    # Rewrites only the stamp, stream-copying everything else. No
    # stream-scoped -map_metadata here, so ffmpeg's default per-stream
    # metadata copy stays on.
    def self.restamp(path, stamp, container = File.extname(path).downcase, output_index = 0, mdta: true)
      temp = File.join(File.dirname(path), ".restamp-#{File.basename(path)}")
      cmd = [
        'ffmpeg', '-hide_banner', '-v', 'error', '-y', '-i', path,
        '-map', '0', '-c', 'copy', '-map_metadata', '0', *RemuxPlan.stamp_args(stamp, container, output_index, mdta: mdta),
        *RemuxPlan.container_args(container, temp), temp
      ]
      _, stderr, status = execute_with_timeout(cmd, NORMALIZATION_TIMEOUT, 'Restamp')
      raise FFmpegError.from_run('Rewriting the neutraliser tags', stderr, status) unless status.success?

      FileUtils.mv(temp, path)
    ensure
      FileUtils.rm_f(temp) if temp
    end

    def self.parse_mode(ffmpeg_output)
      return nil if ffmpeg_output.nil?

      match = ffmpeg_output.match(/Normalization Type:\s*(Linear|Dynamic)/i)
      match && Mode.parse(match[1])
    end

    def self.execute_with_progress(cmd)
      _, stderr, status = execute_with_timeout(cmd, NORMALIZATION_TIMEOUT, 'Normalization')
      raise FFmpegError.from_run('Normalization', stderr, status) unless status.success?

      # ffmpeg writes the loudnorm summary (including "Normalization Type") to stderr
      stderr
    end

    # The real public surface is measure_loudness, apply_normalization,
    # apply_normalization_single_pass, quick_loudness_sample,
    # probe_audio_profile_mid_file, probe_file, version, output_container and decide_codec —
    # everything else is an implementation detail and made genuinely private here (see the NOTE
    # above `execute_with_timeout` on why the old `private` keyword didn't
    # do this).
    private_class_method :execute_with_timeout,
                         :stop_process,
                         :valid_utf8,
                         :timeout_variable,
                         :pin_sample_rate,
                         :parse_loudnorm_json,
                         :estimate_bitrate_from_packets,
                         :loudnorm_lra,
                         :build_loudnorm_filter,
                         :build_audio_filter,
                         :parse_mode,
                         :predict_mode,
                         :build_stamp,
                         :mp4_mdta_safe?,
                         :restamp,
                         :remux_plan,
                         :carry_dialnorm,
                         :source_dialnorm,
                         :execute_with_progress
  end
end
