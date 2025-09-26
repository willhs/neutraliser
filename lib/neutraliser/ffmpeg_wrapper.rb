require 'open3'
require 'json'

module Neutraliser
  class FFmpegError < StandardError; end

  class FFmpegWrapper
    def self.measure_loudness(input_path, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
      cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-i", input_path,
        "-map", "a:0",
        "-af", "loudnorm=I=#{target_i}:TP=#{target_tp}:LRA=#{target_lra}:print_format=json",
        "-f", "null", "-"
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      raise FFmpegError, "Measurement failed: #{status.exitstatus}" unless status.success?

      parse_loudnorm_json(stderr)
    end

    def self.apply_normalization(input_path, output_path, measured_data, target_i: -20.0, target_tp: -1.5, target_lra: 12.0)
      audio_tracks = detect_audio_tracks(input_path)
      primary_channels = detect_audio_channels(input_path)
      primary_codec = select_audio_codec(primary_channels)

      loudnorm_filter = build_loudnorm_filter(measured_data, target_i, target_tp, target_lra)

      cmd = build_complete_ffmpeg_command(
        input_path, output_path, loudnorm_filter,
        primary_codec, audio_tracks
      )

      execute_with_progress(cmd)
    end

    def self.apply_normalization_with_multiple_tracks(input_path, output_path, measured_data, audio_tracks, profile)
      apply_normalization(input_path, output_path, measured_data,
                         target_i: profile[:lufs],
                         target_tp: profile[:tp],
                         target_lra: profile[:lra])
    end

    def self.detect_audio_channels(input_path)
      cmd = [
        "ffprobe", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=channels", "-of", "default=nw=1:nk=1",
        input_path
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise FFmpegError, "Failed to detect audio channels: #{stderr}"
      end

      stdout.to_i
    end

    def self.detect_audio_tracks(input_path)
      cmd = [
        "ffprobe", "-v", "error", "-select_streams", "a",
        "-show_entries", "stream=index,channels,codec_name",
        "-of", "csv=p=0", input_path
      ]

      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        return [{ index: 0, channels: 2, codec: 'unknown' }]
      end

      tracks = stdout.strip.split("\n").map.with_index do |line, idx|
        parts = line.split(',')
        {
          index: idx,
          stream_index: parts[0].to_i,
          channels: parts[1].to_i,
          codec: parts[2] || 'unknown'
        }
      end

      tracks.empty? ? [{ index: 0, channels: 2, codec: 'unknown' }] : tracks
    end

    private

    def self.parse_loudnorm_json(stderr_output)
      json_text = stderr_output[/\{\s*"input_i".*?\}/m]
      raise FFmpegError, "loudnorm JSON not found in output" unless json_text

      JSON.parse(json_text)
    rescue JSON::ParserError => e
      raise FFmpegError, "Failed to parse loudnorm JSON: #{e.message}"
    end

    def self.select_audio_codec(channel_count)
      channel_count >= 6 ? ["-c:a", "ac3", "-b:a", "640k"] : ["-c:a", "aac", "-b:a", "256k"]
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

    def self.build_complete_ffmpeg_command(input_path, output_path, loudnorm_filter, primary_codec, audio_tracks)
      cmd = [
        "ffmpeg", "-hide_banner", "-y", "-i", input_path,
        # Video stream - always copy
        "-map", "0:v", "-c:v", "copy",
        # Primary audio stream - normalize
        "-map", "0:a:0", "-af", loudnorm_filter
      ] + primary_codec

      # Additional audio streams - copy as-is
      if audio_tracks.length > 1
        audio_tracks[1..-1].each do |track|
          cmd += ["-map", "0:a:#{track[:index]}", "-c:a:#{track[:index] + 1}", "copy"]
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
      stdout, stderr, status = Open3.capture3(*cmd)
      unless status.success?
        raise FFmpegError, "FFmpeg normalization failed: #{stderr}"
      end

      stdout
    end
  end
end