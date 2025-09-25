module Neutraliser
  class Processor
    SUPPORTED_FORMATS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze

    def initialize(replace: false, target_level: -16.0)
      @replace = replace
      @target_level = target_level
    end

    def process(path)
      if File.directory?(path)
        process_directory(path)
      elsif File.file?(path)
        process_file(path)
      else
        puts "Error: Path '#{path}' does not exist"
        exit 1
      end
    end

    private

    def process_directory(dir_path)
      video_files = find_video_files(dir_path)

      if video_files.empty?
        puts "No video files found in '#{dir_path}'"
        return
      end

      puts "Found #{video_files.length} video file(s)"
      video_files.each { |file| process_file(file) }
    end

    def process_file(file_path)
      unless video_file?(file_path)
        puts "Skipping '#{file_path}' - not a supported video format"
        return
      end

      puts "Processing: #{file_path}"

      begin
        movie = FFMPEG::Movie.new(file_path)

        unless movie.audio_stream
          puts "  No audio track found, skipping"
          return
        end

        current_level = analyze_loudness(movie)

        if needs_processing?(current_level)
          normalize_file(file_path, current_level)
        else
          puts "  Already at target level, skipping"
        end
      rescue => e
        puts "  Error processing file: #{e.message}"
      end
    end

    def find_video_files(dir_path)
      Dir.glob(File.join(dir_path, '**', '*')).select { |f| video_file?(f) }
    end

    def video_file?(file_path)
      SUPPORTED_FORMATS.include?(File.extname(file_path).downcase)
    end

    def analyze_loudness(movie)
      # Use ffmpeg to measure integrated loudness (LUFS)
      temp_analysis_file = "/tmp/loudness_analysis_#{Time.now.to_i}.txt"

      begin
        # Run ffmpeg loudnorm filter in dual-pass mode to get current loudness
        cmd = [
          'ffmpeg', '-hide_banner', '-nostats',
          '-i', movie.path,
          '-af', 'loudnorm=I=-16:dual_mono=true:TP=-1.5:LRA=11:print_format=summary',
          '-f', 'null', '-',
          '2>', temp_analysis_file
        ].join(' ')

        system(cmd)

        if File.exist?(temp_analysis_file)
          analysis_output = File.read(temp_analysis_file)

          # Parse the integrated loudness from ffmpeg output
          if match = analysis_output.match(/Input Integrated:\s*([-\d.]+)\s*LUFS/)
            integrated_loudness = match[1].to_f
            return integrated_loudness
          end
        end

        # Fallback: use ffprobe for basic volume analysis if loudnorm fails
        fallback_analysis(movie)
      rescue => e
        puts "  Warning: Could not analyze loudness (#{e.message}), using fallback"
        fallback_analysis(movie)
      ensure
        File.delete(temp_analysis_file) if File.exist?(temp_analysis_file)
      end
    end

    def fallback_analysis(movie)
      # Fallback method using ffprobe to get mean volume
      begin
        cmd = [
          'ffprobe', '-hide_banner', '-nostats',
          '-f', 'lavfi',
          '-i', "amovie=#{movie.path},astats=metadata=1:reset=1",
          '-show_entries', 'frame=pkt_pts_time:frame_tags=lavfi.astats.Overall.RMS_level',
          '-of', 'csv=p=0'
        ].join(' ')

        result = `#{cmd} 2>/dev/null`.strip

        if result && !result.empty?
          # Parse RMS levels and calculate approximate LUFS
          rms_values = result.split("\n").map { |line| line.split(',')[1] }.compact.map(&:to_f)
          if rms_values.any?
            avg_rms = rms_values.sum / rms_values.size
            # Convert RMS to approximate LUFS (very rough approximation)
            approximate_lufs = avg_rms - 3.0  # Rough conversion
            return approximate_lufs
          end
        end

        # Final fallback
        -18.0
      rescue
        -18.0
      end
    end

    def needs_processing?(current_level)
      (current_level - @target_level).abs > 0.5
    end

    def normalize_file(file_path, current_level)
      gain_adjustment = @target_level - current_level
      output_path = @replace ? generate_temp_path(file_path) : generate_output_path(file_path)

      puts "  Adjusting by #{gain_adjustment.round(1)}dB"

      movie = FFMPEG::Movie.new(file_path)

      # Copy video stream, reencode audio with volume adjustment
      options = {
        video_codec: 'copy',
        audio_codec: 'aac',
        custom: ['-filter:a', "volume=#{gain_adjustment}dB"]
      }

      movie.transcode(output_path, options) do |progress|
        # Progress callback if needed
      end

      if @replace
        File.rename(output_path, file_path)
        puts "  Replaced: #{file_path}"
      else
        puts "  Saved: #{output_path}"
      end
    end

    def generate_temp_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}_temp_#{Time.now.to_i}#{ext}")
    end

    def generate_output_path(file_path)
      dir = File.dirname(file_path)
      basename = File.basename(file_path, File.extname(file_path))
      ext = File.extname(file_path)

      File.join(dir, "#{basename}_normalized#{ext}")
    end
  end
end