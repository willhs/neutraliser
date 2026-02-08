require 'concurrent'

module Neutraliser
  class ParallelProcessor
    def initialize(max_threads: nil)
      @max_threads = max_threads || calculate_optimal_threads
      @thread_pool = Concurrent::FixedThreadPool.new(@max_threads)
      @results = Concurrent::Array.new
      @errors = Concurrent::Array.new
    end

    def process_files_parallel(files, processor_config)
      futures = files.map do |file|
        Concurrent::Future.execute(executor: @thread_pool) do
          process_single_file(file, processor_config)
        end
      end

      # Wait for all files to complete
      futures.each(&:wait)

      # Collect results and errors
      futures.each_with_index do |future, index|
        if future.fulfilled?
          @results << { file: files[index], result: future.value }
        else
          @errors << { file: files[index], error: future.reason }
        end
      end

      { completed: @results.size, errors: @errors.size }
    end

    def shutdown
      @thread_pool.shutdown
      @thread_pool.wait_for_termination(30) # Wait up to 30 seconds for shutdown
    end

    private

    def calculate_optimal_threads
      # Conservative approach: leave 1-2 cores free for system
      [Concurrent.processor_count - 1, 1].max.clamp(1, 8)
    end

    def process_single_file(file, config)
      processor = Processor.new(
        replace: config[:replace],
        profile: config[:profile],
        tolerance: config[:tolerance],
        cache: config[:cache],
        dry_run: config[:dry_run],
        fast_verify: config[:fast_verify]
      )
      processor.process(file)
    end
  end
end
