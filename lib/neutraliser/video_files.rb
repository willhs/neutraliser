module Neutraliser
  # Finding videos under a directory. The directory is passed as glob's base so
  # it is taken literally: "Movies [HD]" is a name, not a pattern.
  module VideoFiles
    EXTENSIONS = %w[.mp4 .mkv .avi .mov .wmv .flv .webm .m4v].freeze
    LEFTOVER_TEMP = /\A\..*_neutraliser_\h{16}(\.[^.]*)?\z/

    def self.video?(path)
      EXTENSIONS.include?(File.extname(path).downcase)
    end

    def self.under(dir)
      Dir.glob('**/*', base: dir).filter_map do |relative|
        path = File.join(dir, relative)
        path if video?(path) && File.file?(path)
      end
    end

    # Hidden temp outputs a killed run couldn't clean up (SIGKILL, power loss).
    def self.leftover_temps(dir)
      Dir.glob('**/.*_neutraliser_*', base: dir).filter_map do |relative|
        File.join(dir, relative) if LEFTOVER_TEMP.match?(File.basename(relative).scrub)
      end
    end
  end
end
