require 'concurrent'

module Neutraliser
  class ParallelProcessor
    def initialize(max_threads: nil)
      @max_threads = max_threads || calculate_optimal_threads
      @thread_pool = Concurrent::FixedThreadPool.new(@max_threads)
    end

    def process_files_parallel(files, processor_config)
      futures = files.map do |file|
        Concurrent::Future.execute(executor: @thread_pool) do
          process_single_file(file, processor_config)
        end
      end

      results = []
      futures.each_with_index do |future, index|
        future.wait
        file_path = files[index]
        if future.fulfilled?
          result = future.value
          unless result.is_a?(Hash) && result[:status]
            result = {
              file: File.expand_path(file_path),
              status: :failed,
              reason: :invalid_worker_result,
              message: 'Worker did not return a valid file result'
            }
          end
          results << result
        else
          message = future.reason&.message || 'Unknown parallel worker failure'
          results << {
            file: File.expand_path(file_path),
            status: :failed,
            reason: :parallel_worker_error,
            message: message
          }
        end
      end

      {
        results: results,
        done: results.count { |result| result[:status] == :done },
        skipped: results.count { |result| result[:status] == :skipped },
        failed: results.count { |result| result[:status] == :failed }
      }
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
        fast_verify: config[:fast_verify],
        resume: config[:resume],
        fast: config[:fast],
        local_stage: config[:local_stage]
      )
      processor.process_one(file)
    end
  end
end
