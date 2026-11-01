require 'fileutils'
require 'tmpdir'

module Neutraliser
  # Tries a recipe on a random sample of a library and reports its remote-free
  # rate, without touching the library: it copies the sampled files into a
  # scratch folder, runs the processor over the copies (replacing them there),
  # and judges the copies with Report. The library is only ever read.
  #
  # The sample is spread over the roots (say /tv and /movies), not drawn from
  # the pool of every file: a library of a few hundred films and a few
  # thousand episodes would otherwise sample hardly any films. Each root gets
  # an equal share; a root with fewer files than its share gives all it has
  # and the others take up the slack. The seed makes a sample repeatable.
  class RateHarness
    class Error < StandardError; end

    Pick = Data.define(:root, :file) do
      def relative = file.delete_prefix("#{root}/")
      def size = File.size(file)
    end

    # copies: copy path => the Pick it came from. work_dir is set only when the copies were kept.
    # already_done: how many picks an earlier run had normalised, left out of the rate.
    Result = Data.define(:copies, :work_dir, :summary, :report, :seed, :already_done) do
      def rate = report.rate
    end

    attr_reader :seed

    # processor_options: what `Processor.new` takes (profile, allow_dynamic,
    # limit_db ...): the recipe under test. replace/dry_run are the harness's
    # to set.
    def initialize(roots:, size:, seed: nil, processor_options: {}, measure: true, work_dir: nil, keep: false,
                   within_lu: RemoteFreeRate::WITHIN_LU, lra_limit: RemoteFreeRate::LRA_LIMIT,
                   dialogue_anchor: DialogueAnchor::DEFAULT)
      roots.each { |root| raise Error, "'#{root}' is not a directory" unless File.directory?(root) }
      @roots = roots.map { |root| File.realpath(root) }.uniq
      @size = size
      @seed = seed || Random.new_seed
      @processor = Processor.new(**processor_options, replace: true, dry_run: false)
      @measure = measure
      @work_root = work_dir || Dir.tmpdir
      @keep = keep
      @within_lu = within_lu
      @lra_limit = lra_limit
      @dialogue_anchor = dialogue_anchor
      validate!
    end

    # The files that would be copied, and nothing else.
    def plan
      @plan ||= pick
    end

    def run
      picks = plan
      raise Error, 'No video files found under the roots' if picks.empty?

      check_room(picks)
      work = Dir.mktmpdir('neutraliser-rate-', @work_root)
      begin
        copies = copy_all(picks, work)
        summary = @processor.process(work)
        already_done = drop_already_done(summary)
        report = Report.new(work, measure: @measure, profile: @processor.profile, within_lu: @within_lu,
                                  lra_limit: @lra_limit, dialogue_anchor: @dialogue_anchor)
        Result.new(copies: copies, work_dir: (work if @keep), summary: summary,
                   report: report, seed: @seed, already_done: already_done)
      ensure
        FileUtils.remove_entry(work) if !@keep && Dir.exist?(work)
      end
    end

    private

    # A copy already stamped for this profile is skipped, so the recipe under test never
    # touched it: measuring it would credit the recipe with what an earlier run did.
    def drop_already_done(summary)
      done = Array(summary[:results]).select { |result| result.reason == :already_processed }
      done.each { |result| FileUtils.rm_f(result.file) }
      done.size
    end

    def validate!
      raise Error, 'Give at least one root' if @roots.empty?
      raise Error, 'The sample size must be at least 1' unless @size.to_i.positive?

      work_real = resolve(@work_root)
      inside = @roots.find { |root| work_real == root || work_real.start_with?("#{root}/") }
      raise Error, "The work folder '#{@work_root}' is inside '#{inside}'; it must be outside the library" if inside

      FileUtils.mkdir_p(@work_root)
    end

    # Where a path really is, before it exists (nothing may be created in a library to find out):
    # symlinks resolved on the part that exists, the rest appended.
    def resolve(path)
      path = File.expand_path(path)
      missing = []
      until File.exist?(path)
        missing.unshift(File.basename(path))
        path = File.dirname(path)
      end
      File.join(File.realpath(path), *missing)
    end

    def pick
      rng = Random.new(@seed)
      queues = @roots.to_h { |root| [root, candidate_files(root).shuffle(random: rng)] }
      order = @roots.shuffle(random: rng)
      picked = []
      until picked.size == @size || queues.values.all?(&:empty?)
        order.each do |root|
          break if picked.size == @size

          file = queues[root].shift
          picked << Pick.new(root: root, file: file) if file
        end
      end
      picked.sort_by(&:file)
    end

    # Not this tool's own leftovers: a `_normalized` copy or an interrupted run's temp.
    def candidate_files(root)
      VideoFiles.under(root).reject do |file|
        base = File.basename(file, File.extname(file))
        base.end_with?(Processor::NORMALIZED_SUFFIX) || File.basename(file).match?(VideoFiles::LEFTOVER_TEMP)
      end.sort
    end

    # Replacing a file needs room for it and one more copy of the biggest.
    def check_room(picks)
      free = DiskGuard.new.free_bytes(@work_root)
      need = picks.sum(&:size) + picks.map(&:size).max
      return if free.nil? || free >= need

      raise Error, "Not enough room in #{@work_root}: the sample needs about #{need.fdiv(DiskGuard::GIB).round(1)} GiB " \
                   "and #{free.fdiv(DiskGuard::GIB).round(1)} GiB is free"
    end

    # Each root gets its own folder, so equal relative paths in two roots stay apart.
    def copy_all(picks, work)
      picks.to_h do |pick|
        root_dir = File.join(work, "#{@roots.index(pick.root) + 1}-#{File.basename(pick.root)}")
        copy = File.join(root_dir, pick.relative)
        FileUtils.mkdir_p(File.dirname(copy))
        FileUtils.cp(pick.file, copy)
        [copy, pick]
      end
    rescue SystemCallError => e
      raise Error, "Could not copy the sample (#{e.message})"
    end
  end
end
