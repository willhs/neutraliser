module Neutraliser
  # The one rewrite of a file: the ffmpeg command that replaces the primary audio
  # track with its normalised version and stream-copies everything else around it,
  # built from an AudioLayout (which output stream is which), the filter graph, the
  # codec decision and the stamp. Pure computation: nothing here runs ffmpeg.
  #
  # Why one value: the output's audio order, the per-stream -map_metadata that
  # carries language and title across, the dispositions and the stamp's stream index
  # all hang on the same layout. Built apart, they drift (the metadata-loss bugs).
  class RemuxPlan
    # Stream kinds whose tags have to be mapped one by one (audio is mapped by layout).
    COPIED_KINDS = { 'v' => :video, 's' => :subtitle, 't' => :attachment }.freeze

    attr_reader :layout, :container, :mdta

    # source: the Source being rewritten. container: what the output really is (see
    # FFmpegWrapper.output_container). mdta: whether an MP4 may take the stamp as mdta keys.
    def initialize(source, output_path, container:, mdta:, filter:, codec_decision:, stamp:, keep_original:)
      @source = source
      @output_path = output_path
      @container = container
      @mdta = mdta
      @filter = filter
      @codec_decision = codec_decision
      @stamp = stamp
      @layout = AudioLayout.for(source, keep_original: keep_original)
      raise ArgumentError, "#{source.path} has no audio to normalise" unless layout.normalised
    end

    # The stamp goes on the normalised audio stream and on the container. MP4/MOV only
    # keep arbitrary keys at container level, and only with use_metadata_tags; their
    # stream-level copy is silently dropped. mdta: false leaves that flag off, and the
    # muxer then drops the stamp altogether.
    def self.stamp_args(stamp, container, output_index, mdta: true)
      args = stamp.to_tags.flat_map do |key, value|
        ["-metadata:s:a:#{output_index}", "#{key}=#{value}", '-metadata', "#{key}=#{value}"]
      end
      args += ['-movflags', '+use_metadata_tags'] if mdta && FFmpegWrapper::MP4_FAMILY.include?(container)
      args
    end

    # `-f` for an output whose extension doesn't say its container.
    def self.container_args(container, output_path)
      container == File.extname(output_path).downcase ? [] : ['-f', container.delete_prefix('.')]
    end

    def argv
      [
        # The decode hears the stream as the viewer who turned DRC off does, as the measurement did.
        'ffmpeg', '-hide_banner', '-y', *DolbyStream::DRC_OFF, '-i', @source.path,
        # Video stream - always copy
        '-map', '0:v?', '-c:v', 'copy',
        '-filter_complex', "[0:a:#{layout.normalised.source_index}]#{@filter}[norm]",
        *audio_map_args,
        # An explicit stream-scoped -map_metadata turns ffmpeg's automatic per-stream
        # metadata copy off for the whole command, and the filtered primary track has
        # no source stream to copy from anyway. So every output stream, not just the
        # primary, is mapped back to its source stream by hand.
        '-map_chapters', '0', '-map_metadata', '0',
        *audio_metadata_args,
        *disposition_args(layout.normalised),
        *kept_original_args,
        *copied_metadata_args,
        '-map', '0:s?', '-c:s', 'copy',
        # Attachments are mostly the fonts styled subtitles need to render.
        '-map', '0:t?', '-c:t', 'copy',
        *stamp_args(@stamp),
        *self.class.container_args(container, @output_path),
        @output_path
      ]
    end

    # The stamp's tags for this plan's output (a different stamp for a restamp).
    def stamp_args(stamp)
      self.class.stamp_args(stamp, container, layout.normalised.index, mdta: @mdta)
    end

    private

    def audio_map_args
      layout.outputs.flat_map do |output|
        case output.role
        when :normalised then ['-map', '[norm]', *codec_args(output.index)]
        else ['-map', "0:a:#{output.source_index}", "-c:a:#{output.index}", 'copy']
        end
      end
    end

    def codec_args(index)
      args = ["-c:a:#{index}", @codec_decision[:encoder]]
      args += ["-b:a:#{index}", "#{@codec_decision[:bitrate] / 1000}k"] if @codec_decision[:bitrate]
      args += ["-dialnorm:a:#{index}", @codec_decision[:dialnorm].to_s] if @codec_decision[:dialnorm]
      args
    end

    # Every output audio stream but the kept original (which has its own extras below).
    def audio_metadata_args
      layout.outputs.reject { |o| o.role == :kept_original }.flat_map { |o| metadata_map(o) }
    end

    def metadata_map(output)
      ["-map_metadata:s:a:#{output.index}", "0:s:a:#{output.source_index}"]
    end

    def disposition_args(output)
      return [] unless output.dispositions

      ["-disposition:a:#{output.index}", output.dispositions.empty? ? '0' : output.dispositions.join('+')]
    end

    def kept_original_args
      kept = layout.kept_original
      return [] unless kept

      title = AudioLayout.original_title(@source.audio_tracks[kept.source_index])
      args = [*metadata_map(kept), "-metadata:s:a:#{kept.index}", "title=#{title}", *disposition_args(kept)]
      # MP4 has no stream title; players show its handler name instead.
      mp4 = FFmpegWrapper::MP4_FAMILY.include?(File.extname(@output_path).downcase)
      mp4 ? args + ["-metadata:s:a:#{kept.index}", "handler_name=#{title}"] : args
    end

    def copied_metadata_args
      counts = @source.stream_counts
      COPIED_KINDS.flat_map do |letter, kind|
        Array.new(counts.fetch(kind)) { |i| ["-map_metadata:s:#{letter}:#{i}", "0:s:#{letter}:#{i}"] }.flatten
      end
    end
  end
end
