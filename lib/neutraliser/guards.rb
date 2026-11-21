require 'securerandom'

module Neutraliser
  # The checks a file passes before anything is encoded, each answering one
  # question about the file, the facts the Source holds and the run's options:
  # may we go on? Every check returns a Verdict; none logs, records or raises.
  # Processor logs `verdict.log`, turns a skip or fail into a FileResult and a
  # disk abort into DiskGuard::Abort, so a guard is tested with a file, a Source
  # and options, with no Processor.
  #
  # Two sequences, because the second runs on the working copy (--local-stage
  # copies the file first, so these reads come off local disk):
  #   before_staging: folder takes a new file, disk space, has audio, subtitles copyable
  #   after_staging:  object audio, channel count, codec change
  # Each returns the first verdict that stops the file, else proceed. The log
  # lines of checks that let the file through (a note, a warning) ride along.
  class Guards
    # action is :proceed, :skip (left as it is), :fail or :abort (stop the whole run).
    # reason and message are what the FileResult will carry; left is the LeftRecord a
    # skip persists; log is the lines to print, in order.
    Verdict = Data.define(:action, :reason, :message, :left, :log) do
      def self.proceed(log = []) = new(action: :proceed, reason: nil, message: nil, left: nil, log: log)

      def self.skip(reason, log:, message: nil, left: nil)
        new(action: :skip, reason: reason, message: message, left: left, log: log)
      end

      def self.failure(reason, log:, message:) = new(action: :fail, reason: reason, message: message, left: nil, log: log)
      def self.abort(message) = new(action: :abort, reason: nil, message: message, left: nil, log: [])

      def proceed? = action == :proceed
      def abort? = action == :abort

      # What a file stopped here is recorded as; nil for proceed and abort.
      def status = { skip: :skipped, fail: :failed }[action]
    end

    PROCEED = Verdict.proceed.freeze

    # How the too_many_channels message names each --lossy71 value.
    LOSSY_71_NAMES = { 'aac' => 'AAC', 'opus' => 'Opus' }.freeze

    # object_audio_undetectable: this ffmpeg is too old to name Atmos / DTS:X, so a
    # file named as such is skipped rather than guessed at (see ObjectAudio.undetectable?).
    def initialize(profile:, replace:, dry_run:, disk_guard:, allow_object_audio_loss:, allow_codec_change:,
                   object_audio_undetectable: false, recipe: Recipe::CURRENT, lossy71: nil)
      @profile = profile
      @lossy71 = lossy71
      @recipe = recipe
      @replace = replace
      @dry_run = dry_run
      @disk_guard = disk_guard
      @allow_object_audio_loss = allow_object_audio_loss
      @allow_codec_change = allow_codec_change
      @object_audio_undetectable = object_audio_undetectable
      @write_blockers = {}
    end

    def before_staging(file_path, source)
      first_stop(-> { writable(file_path) }, -> { disk_space(file_path) },
                 -> { audio_stream(source) }, -> { subtitles(source) })
    end

    # Recorded by the caller as left alone, never as done: a later
    # --allow-object-audio-loss run (or an ffmpeg that can keep the objects) must
    # still see the file.
    def after_staging(file_path, working)
      first_stop(-> { object_audio(file_path, working) }, -> { channel_count(file_path, working) },
                 -> { codec_change(file_path, working) })
    end

    # The output lands beside the original (temp + rename with --replace, a
    # _normalized copy without), so a folder we can't write to fails every file in
    # it, but only after a full analysis pass each. Proving the folder writable
    # first turns that into one cheap check per folder. A dry run writes nothing.
    def writable(file_path)
      return PROCEED if @dry_run

      dir = output_dir(file_path)
      blocker = write_blocker(dir)
      return PROCEED unless blocker

      message = "can't write to #{dir} (#{blocker}); fix the folder's permissions"
      Verdict.failure(:not_writable, message: message, log: ["  Not writable: #{message}"])
    end

    # Low space skips this file (a smaller one may still fit); critically low space
    # stops the run. Nothing is recorded, so a later run retries.
    def disk_space(file_path)
      return PROCEED if @dry_run || !@disk_guard.enabled?

      dir = output_dir(file_path)
      case @disk_guard.verdict(dir, File.size(file_path))
      when :abort then Verdict.abort("free space on #{dir} is below the abort floor")
      when :skip then Verdict.skip(:low_disk, log: ['  Not enough free space for this file, skipping'])
      else PROCEED
      end
    end

    # A file with nothing to level: unreadable (a failure, it may be mid-write) or
    # readable but silent of audio (a skip). The first fact asked of the Source is
    # the run's one probe of this file.
    def audio_stream(source)
      unless source.readable?
        message = 'ffprobe could not read this file; it may be corrupt or still being written'
        return Verdict.failure(:unreadable, message: message, log: ["  Unreadable: #{message}"])
      end
      return PROCEED if source.audio?

      Verdict.skip(:no_audio_track, log: ['  No audio track found, skipping'])
    end

    # Subtitles are copied as-is, never dropped. One ffmpeg can't identify can't be
    # copied either, so the encode would fail after a full analysis pass; fail the
    # file up front with a countable reason instead.
    def subtitles(source)
      unsupported = source.unsupported_subtitles
      return PROCEED if unsupported.empty?

      message = "subtitle #{unsupported.join(', ')} can't be copied by this ffmpeg; " \
                'remux or remove it to process this file'
      Verdict.failure(:unsupported_subtitle, message: message, log: ["  Unsupported subtitle: #{message}"])
    end

    # ffmpeg can't encode Atmos/DTS:X object metadata, so re-encoding the primary
    # track flattens it to plain channel audio. Skips, unless there is none or the
    # user accepted the loss.
    def object_audio(original_path, working)
      primary_track = working.primary_track
      verdict = ObjectAudio.detect(working, name: File.basename(original_path))

      if verdict.status == :suspected
        return suspected_object_audio(primary_track) if @object_audio_undetectable && !@allow_object_audio_loss

        return Verdict.proceed(["  Note: name suggests object audio but ffprobe found none on the #{primary_track[:codec]} track, " \
                                'processing'])
      end
      return PROCEED unless verdict.object_audio?

      if @allow_object_audio_loss
        return Verdict.proceed(["  Warning: primary track is #{verdict.profile}; re-encoding drops the object audio " \
                                '(--allow-object-audio-loss)'])
      end

      left_alone(:object_audio, verdict.profile,
                 "  Object audio (#{verdict.profile}): re-encoding would strip it, skipping " \
                 '(--allow-object-audio-loss to process anyway)')
    end

    # A track with more channels than any encoder this run may use in this container holds (E-AC-3 7.1
    # in an MP4: ffmpeg's AC-3 / E-AC-3 stop at 5.1, FLAC isn't allowed, and AAC / Opus 7.1 come only
    # with --lossy71). Writing it would fail the output check after a full measure, on every sweep, so
    # skip it first. Recorded as left alone: --lossy71, a different container or ffmpeg could. The
    # message names the --lossy71 values that would work here.
    def channel_count(original_path, working)
      return PROCEED unless working.audio?

      track = working.primary_track
      container = FFmpegWrapper.output_container(working, original_path)
      return PROCEED if CodecChoice.decide(track, container, lossy71: @lossy71)[:encodable]

      message = "#{track[:codec]} with #{track[:channels]} channels can't be re-encoded in #{container} as it is: " \
                "ffmpeg's AC-3 and E-AC-3 stop at 5.1 and #{container} takes no FLAC#{lossy71_hint(track, container)}"
      left_alone(:too_many_channels, message, "  Too many channels (#{message}), skipping")
    end

    # Re-encoding to a different codec isn't leveling the volume, it's converting
    # the track. Skipped unless the user accepts it. A lossy 7.1 track going to FLAC
    # gets a note of the size cost either way.
    def codec_change(original_path, working)
      return PROCEED unless working.audio?

      choice = CodecChoice.decide(working.primary_track, FFmpegWrapper.output_container(working, original_path),
                                  lossy71: @lossy71)
      return PROCEED unless choice[:changes_codec]
      return Verdict.proceed(flac_71_note(working, choice)) if @allow_codec_change

      message = "#{working.primary_track[:codec]} would be re-encoded as #{choice[:encoder]}"
      verdict = left_alone(:codec_change, message,
                           "  Codec change (#{message}), skipping (--allow-codec-change to process anyway)")
      verdict.with(log: verdict.log + flac_71_note(working, choice))
    end

    private

    # The end of the too_many_channels message: the --lossy71 values that would write this track here.
    def lossy71_hint(track, container)
      options = CodecChoice.lossy71_options(track, container) - [@lossy71]
      return '' if options.empty?

      "; --lossy71 #{options.join(' or ')} with --allow-codec-change levels it as " \
        "#{options.map { |option| LOSSY_71_NAMES.fetch(option) }.join(' or ')} 7.1"
    end

    # A lossy over-5.1 track about to become (or skipped for becoming) FLAC: what that costs, and the
    # opt-in lossy route. None for a lossless source, where FLAC is no bigger.
    def flac_71_note(working, choice)
      track = working.primary_track
      return [] unless choice[:encoder] == 'flac' && track[:channels].to_i > 6 &&
                       CodecChoice.lossy_source?(choice[:source_codec], track)

      ["  Note: #{CodecChoice::FLAC_71_COST}; --lossy71 aac keeps it lossy"]
    end

    # The first verdict that stops the file, else proceed. The lines of the checks
    # that let it through are kept and come before the stopper's.
    def first_stop(*checks)
      log = []
      checks.each do |check|
        verdict = check.call
        log += verdict.log
        return verdict.with(log: log) unless verdict.proceed?
      end
      Verdict.proceed(log)
    end

    def suspected_object_audio(primary_track)
      left_alone(:object_audio, 'suspected from the name',
                 "  Name suggests object audio and this ffmpeg can't check the #{primary_track[:codec]} track, skipping " \
                 '(--allow-object-audio-loss to process anyway)')
    end

    # A skip the sidecar remembers as left alone (LeftRecord), not as done.
    def left_alone(reason, message, line)
      Verdict.skip(reason, message: message, log: [line], left: LeftRecord.for(reason, @profile, message: message, recipe: @recipe))
    end

    # Where the output is written: beside the real file when --replace goes
    # through a symlink, since the real file is the one that gets replaced.
    def output_dir(file_path)
      File.dirname(@replace && File.symlink?(file_path) ? File.realpath(file_path) : File.expand_path(file_path))
    end

    # nil when the directory takes a new file, else why not. Memoised: permissions
    # are a property of the folder, and a TV season is one folder.
    def write_blocker(dir)
      return @write_blockers[dir] if @write_blockers.key?(dir)

      @write_blockers[dir] = begin
        probe = File.join(dir, ".neutraliser-write-check-#{Process.pid}-#{SecureRandom.hex(4)}")
        File.open(probe, File::WRONLY | File::CREAT | File::EXCL) { nil }
        File.delete(probe)
        nil
      rescue SystemCallError => e
        SystemCallError.new(nil, e.errno).message # "Permission denied", without Ruby's call site and path
      end
    end
  end
end
