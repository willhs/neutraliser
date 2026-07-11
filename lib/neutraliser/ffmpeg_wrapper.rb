require 'open3'
require 'json'

module Neutraliser
  class FFmpegError < StandardError; end
  class FFmpegTimeoutError < FFmpegError; end

  class FFmpegWrapper
    # Timeout constants (in seconds)
    ANALYSIS_TIMEOUT = 300    # 5 minutes for full analysis
    QUICK_TIMEOUT = 120       # 2 minutes for quick operations
    NORMALIZATION_TIMEOUT = 1800  # 30 minutes for normalization
    PROBE_TIMEOUT = 30        # 30 seconds for ffprobe

    # Mapping from source codec to ffmpeg encoder name
    # Only codecs that ffmpeg can reliably encode
    ENCODABLE_CODECS = {
      'aac'       => 'aac',
      'ac3'       => 'ac3',
      'eac3'      => 'eac3',
      'mp3'       => 'libmp3lame',
      'mp2'       => 'libtwolame',
      'opus'      => 'libopus',
      'vorbis'    => 'libvorbis',
      'flac'      => 'flac',
      'pcm_s16le' => 'pcm_s16le',
      'pcm_s16be' => 'pcm_s16be',
      'pcm_s24le' => 'pcm_s24le',
      'pcm_f32le' => 'pcm_f32le',
    }.freeze

    # Codecs considered lossless
    LOSSLESS_CODECS = %w[flac pcm_s16le pcm_s16be pcm_s24le pcm_f32le truehd pcm_s32le].freeze

    # Minimum quality floor bitrates per encoder (in bps)
    QUALITY_FLOORS = {
      'aac'        => { 2 => 128_000, 6 => 256_000 },
      'ac3'        => { 2 => 192_000, 6 => 384_000 },
      'eac3'       => { 2 => 128_000, 6 => 256_000 },
      'libmp3lame' => { 2 => 192_000 },
      'libtwolame' => { 2 => 192_000 },
      'libopus'    => { 2 => 128_000, 6 => 256_000 },
      'libvorbis'  => { 2 => 128_000, 6 => 256_000 },
    }.freeze

    # Maximum useful bitrates per encoder (in bps)
    QUALITY_CAPS = {
      'aac'        => { 2 => 320_000, 6 => 512_000 },
      'ac3'        => { 2 => 640_000, 6 => 640_000 },
      'eac3'       => { 2 => 640_000, 6 => 1_536_000 },
      'libmp3lame' => { 2 => 320_000 },
      'libtwolame' => { 2 => 384_000 },
      'libopus'    => { 2 => 256_000, 6 => 510_000 },
      'libvorbis'  => { 2 => 256_000, 6 => 500_000 },
    }.freeze

    # Container compatibility — which encoders work in which containers
    CONTAINER_CODECS = {
      '.mp4'  => %w[aac ac3 eac3 libmp3lame libopus],
      '.m4v'  => %w[aac ac3 eac3 libmp3lame libopus],
      '.mov'  => %w[aac ac3 eac3 libmp3lame pcm_s16le pcm_s24le],
      '.mkv'  => %w[aac ac3 eac3 libmp3lame libtwolame libopus libvorbis flac pcm_s16le pcm_s24le pcm_f32le],
      '.webm' => %w[libopus libvorbis],
      '.avi'  => %w[aac ac3 libmp3lame pcm_s16le],
      '.wmv'  => %w[aac ac3 libmp3lame],
      '.flv'  => %w[aac libmp3lame],
    }.freeze

    # Preferred fallback codec per container when source codec can't be matched
    CONTAINER_FALLBACKS = {
      '.mkv'  => 'flac',
      '.mp4'  => 'aac',
      '.m4v'  => 'aac',
      '.mov'  => 'aac',
      '.webm' => 'libopus',
      '.avi'  => 'aac',
      '.wmv'  => 'aac',
      '.flv'  => 'aac',
    }.freeze

    def self.measure_loudness(input_path, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
      cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-i", input_path,
        "-map", "a:0",
        "-af", "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}:print_format=json",
        "-f", "null", "-"
      ]

      stdout, stderr, status = execute_with_timeout(cmd, ANALYSIS_TIMEOUT, "Loudness measurement")
      unless status.success?
        exit_status = status.respond_to?(:exitstatus) ? status.exitstatus : "unknown"
        raise FFmpegError, "Measurement failed (exit #{exit_status}): #{stderr}"
      end

      parse_loudnorm_json(stderr)
    end

    def self.quick_loudness_sample(input_path, duration: 30, target_i: -20.0)
      # Quick LUFS estimation using a sample from the middle of the file
      # Much faster than analyzing the entire file

      # First get the total duration
      duration_cmd = [
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nw=1:nk=1", input_path
      ]

      stdout, stderr, status = execute_with_timeout(duration_cmd, PROBE_TIMEOUT, "Duration probe")
      return nil unless status.success?

      total_duration = stdout.to_f
      return nil if total_duration < duration * 2 # File too short for meaningful sample

      # Start sampling from middle of file
      start_time = (total_duration - duration) / 2

      cmd = [
        "ffmpeg", "-hide_banner", "-nostats",
        "-ss", start_time.to_s, "-i", input_path,
        "-t", duration.to_s,
        "-map", "a:0",
        "-af", "loudnorm=I=#{target_i}:print_format=json",
        "-f", "null", "-"
      ]

      stdout, stderr, status = execute_with_timeout(cmd, QUICK_TIMEOUT, "Quick loudness sample")
      return nil unless status.success?

      parse_loudnorm_json(stderr)
    rescue => e
      # Return nil on any error to fall back to full analysis
      nil
    end

    def self.apply_normalization(input_path, output_path, measured_data, target_i: -20.0, target_tp: -1.5, target_lra: 12.0, audio_tracks: nil, linear_only: false)
      audio_tracks ||= detect_audio_tracks(input_path)
      primary_track = audio_tracks.first || { index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }

      codec_decision = select_output_codec(primary_track, output_path)
      codec_args = build_codec_args(codec_decision)

      audio_filter, forced_normalization_type = build_audio_filter(
        measured_data, target_i, target_tp, target_lra, primary_track[:sample_rate], linear_only: linear_only
      )

      cmd = build_complete_ffmpeg_command(
        input_path, output_path, audio_filter,
        codec_args, audio_tracks
      )

      ffmpeg_output = execute_with_progress(cmd)
      normalization_type = forced_normalization_type || parse_normalization_type(ffmpeg_output) || 'Unknown'

      codec_decision.merge(normalization_type: normalization_type)
    end

    def self.apply_normalization_with_multiple_tracks(input_path, output_path, measured_data, audio_tracks, profile, linear_only: false)
      apply_normalization(input_path, output_path, measured_data,
                         target_i: profile[:lufs],
                         target_tp: profile[:tp],
                         target_lra: profile[:lra],
                         audio_tracks: audio_tracks,
                         linear_only: linear_only)
    end

    def self.apply_normalization_single_pass(input_path, output_path, audio_tracks, profile)
      audio_tracks ||= detect_audio_tracks(input_path)
      primary_track = audio_tracks.first || { index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }

      codec_decision = select_output_codec(primary_track, output_path)
      codec_args = build_codec_args(codec_decision)

      loudnorm_filter = "loudnorm=I=#{profile[:lufs]}:TP=#{profile[:tp]}:LRA=#{profile[:lra]}:print_format=summary"
      loudnorm_filter += ",aresample=#{primary_track[:sample_rate]}" if primary_track[:sample_rate]

      cmd = build_complete_ffmpeg_command(
        input_path, output_path, loudnorm_filter,
        codec_args, audio_tracks
      )

      ffmpeg_output = execute_with_progress(cmd)
      # Single-pass loudnorm has no prior measurement pass, so it always
      # behaves as dynamic (per-frame) normalization regardless of the
      # filter's default linear setting.
      normalization_type = parse_normalization_type(ffmpeg_output) || 'Dynamic'

      codec_decision.merge(normalization_type: normalization_type)
    end

    def self.detect_audio_tracks(input_path)
      cmd = [
        "ffprobe", "-v", "error", "-select_streams", "a",
        "-show_entries", "stream=index,codec_name,sample_rate,channels,bit_rate",
        "-of", "json", input_path
      ]

      stdout, stderr, status = execute_with_timeout(cmd, PROBE_TIMEOUT, "Audio track detection")
      unless status.success?
        return [{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }]
      end

      tracks = parse_audio_tracks_json(stdout)

      tracks.empty? ? [{ index: 0, channels: 2, codec: 'unknown', bit_rate: nil, sample_rate: nil }] : tracks
    end

    def self.parse_audio_tracks_json(json_text)
      data = JSON.parse(json_text)
      streams = data['streams'] || []

      streams.each_with_index.map do |stream, idx|
        {
          index: idx,
          stream_index: stream['index'].to_i,
          channels: stream['channels'].to_i,
          codec: stream['codec_name'] || 'unknown',
          bit_rate: parse_bit_rate(stream['bit_rate']),
          sample_rate: stream['sample_rate']&.to_i
        }
      end
    rescue JSON::ParserError
      []
    end

    def self.parse_bit_rate(value)
      return nil if value.nil? || value == 'N/A'

      value.to_i
    end

    private

    def self.execute_with_timeout(cmd, timeout_seconds, operation_name)
      # Use Open3.popen3 with manual timeout to avoid thread corruption from Timeout.timeout
      stdout_str = ""
      stderr_str = ""
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
            # Timeout - kill the process
            Process.kill('TERM', wait_thr.pid) rescue nil
            sleep(1)
            Process.kill('KILL', wait_thr.pid) rescue nil
            raise FFmpegTimeoutError, "#{operation_name} timed out after #{timeout_seconds}s - file may be corrupted or have unsupported codec"
          end

          # Check which streams have data available (with 1 second timeout per iteration)
          ready = IO.select([stdout, stderr].compact, nil, nil, 1)
          next unless ready

          ready[0].each do |io|
            begin
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
        end

        status = wait_thr.value
      end

      [stdout_str, stderr_str, status]
    end

    def self.parse_loudnorm_json(stderr_output)
      json_text = stderr_output[/\{\s*"input_i".*?\}/m]
      raise FFmpegError, "loudnorm JSON not found in output" unless json_text

      JSON.parse(json_text)
    rescue JSON::ParserError => e
      raise FFmpegError, "Failed to parse loudnorm JSON: #{e.message}"
    end

    def self.select_output_codec(track, output_path)
      source_codec = track[:codec]&.downcase || 'unknown'
      channels = track[:channels].to_i
      channels = 2 if channels == 0
      source_bitrate = track[:bit_rate].to_i
      container = File.extname(output_path).downcase

      allowed = CONTAINER_CODECS.fetch(container, CONTAINER_CODECS['.mkv'])

      encoder = resolve_encoder(source_codec, allowed, container, channels)
      bitrate = resolve_bitrate(encoder, source_bitrate, channels)

      {
        encoder: encoder,
        bitrate: bitrate,
        source_codec: source_codec,
        source_bitrate: source_bitrate,
        lossless_output: lossless_encoder?(encoder)
      }
    end

    def self.resolve_encoder(source_codec, allowed, container, channels)
      # 1. Try direct match — same codec if encodable and allowed in container
      direct = ENCODABLE_CODECS[source_codec]
      return direct if direct && allowed.include?(direct)

      # 2. Lossless source — prefer lossless output if container supports it
      if LOSSLESS_CODECS.include?(source_codec)
        return 'flac' if allowed.include?('flac')
        return 'pcm_s24le' if allowed.include?('pcm_s24le')
        return 'pcm_s16le' if allowed.include?('pcm_s16le')
      end

      # 3. Non-encodable surround — prefer lossless if container supports it, else AC3/EAC3
      if channels >= 6
        return 'flac' if allowed.include?('flac')
        return 'eac3' if allowed.include?('eac3')
        return 'ac3' if allowed.include?('ac3')
      end

      # 4. Container default fallback
      fallback = CONTAINER_FALLBACKS.fetch(container, 'aac')
      return fallback if allowed.include?(fallback)

      # 5. Last resort — first allowed codec
      allowed.first || 'aac'
    end

    def self.resolve_bitrate(encoder, source_bitrate, channels)
      return nil if lossless_encoder?(encoder)

      channel_key = channels >= 6 ? 6 : 2
      floor = QUALITY_FLOORS.dig(encoder, channel_key) || QUALITY_FLOORS.dig(encoder, 2) || 128_000
      cap = QUALITY_CAPS.dig(encoder, channel_key) || QUALITY_CAPS.dig(encoder, 2) || 640_000

      if source_bitrate > 0
        [[source_bitrate, floor].max, cap].min
      else
        floor
      end
    end

    def self.lossless_encoder?(encoder)
      encoder.start_with?('flac', 'pcm_')
    end

    def self.build_codec_args(codec_decision)
      args = ["-c:a:0", codec_decision[:encoder]]
      if codec_decision[:bitrate]
        args += ["-b:a:0", "#{codec_decision[:bitrate] / 1000}k"]
      end
      args
    end

    def self.build_loudnorm_filter(measured, target_i, target_tp, target_lra)
      "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}" \
      ":measured_I=#{measured['input_i']}" \
      ":measured_TP=#{measured['input_tp']}" \
      ":measured_LRA=#{measured['input_lra']}" \
      ":measured_thresh=#{measured['input_thresh']}" \
      ":offset=#{measured['target_offset']}" \
      ":linear=true:print_format=summary"
    end

    # Builds the audio filter chain to apply during the normalization pass.
    #
    # Returns [filter_string, forced_normalization_type]. forced_normalization_type
    # is nil when the filter is loudnorm (its actual Linear/Dynamic behavior can
    # only be known after ffmpeg runs, by parsing its summary output) and 'Linear'
    # when linear_only mode is used (a plain gain filter that can never engage
    # dynamic compression).
    def self.build_audio_filter(measured, target_i, target_tp, target_lra, source_sample_rate, linear_only:)
      if linear_only
        filter = build_volume_gain_filter(measured, target_i, target_tp)
        forced_normalization_type = 'Linear'
      else
        filter = build_loudnorm_filter(measured, target_i, target_tp, target_lra)
        forced_normalization_type = nil
      end

      filter += ",aresample=#{source_sample_rate}" if source_sample_rate

      [filter, forced_normalization_type]
    end

    # A constant-gain volume adjustment, capped so the output true peak never
    # exceeds target_tp. This guarantees zero dynamic-range change — unlike
    # loudnorm's linear mode, it cannot silently fall back to dynamic
    # (per-frame) compression. Quiet-but-peaky sources land shy of target_i
    # rather than being squashed.
    def self.build_volume_gain_filter(measured, target_i, target_tp)
      gain = capped_linear_gain(measured, target_i, target_tp)
      "volume=#{format('%.2f', gain)}dB"
    end

    def self.capped_linear_gain(measured, target_i, target_tp)
      desired_gain = target_i - measured['input_i'].to_f
      max_safe_gain = target_tp - measured['input_tp'].to_f
      [desired_gain, max_safe_gain].min
    end

    def self.parse_normalization_type(ffmpeg_output)
      return nil if ffmpeg_output.nil?

      match = ffmpeg_output.match(/Normalization Type:\s*(Linear|Dynamic)/i)
      match && match[1].capitalize
    end

    def self.build_complete_ffmpeg_command(input_path, output_path, loudnorm_filter, primary_codec, audio_tracks)
      cmd = [
        "ffmpeg", "-hide_banner", "-y", "-i", input_path,
        # Video stream - always copy
        "-map", "0:v", "-c:v", "copy"
      ]

      # Primary audio stream - normalize using filter_complex
      cmd += [
        "-filter_complex", "[0:a:0]#{loudnorm_filter}[norm]",
        "-map", "[norm]"
      ] + primary_codec

      # Additional audio streams - copy as-is with explicit indexing
      if audio_tracks.length > 1
        audio_tracks[1..-1].each_with_index do |track, idx|
          output_index = idx + 1
          cmd += ["-map", "0:a:#{track[:index]}", "-c:a:#{output_index}", "copy"]
        end
      end

      # Metadata and subtitles preservation
      cmd += [
        "-map_chapters", "0", "-map_metadata", "0",
        "-map", "0:s?", "-c:s", "copy",
        output_path
      ]

      cmd
    end

    def self.execute_with_progress(cmd)
      stdout, stderr, status = execute_with_timeout(cmd, NORMALIZATION_TIMEOUT, "Normalization")
      unless status.success?
        raise FFmpegError, "FFmpeg normalization failed: #{stderr}"
      end

      # ffmpeg writes the loudnorm summary (including "Normalization Type") to stderr
      stderr
    end
  end
end
