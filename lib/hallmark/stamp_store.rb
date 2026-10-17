# typed: strict
# frozen_string_literal: true

require "fileutils"

module Hallmark
  # Writes stamps off the request thread. `record` only pushes the event onto
  # a queue; a flusher thread dedupes events into stamps and appends each new
  # stamp to one JSONL file per process:
  #
  #   tmp/hallmark/stamps-<run>-<pid>.jsonl
  #
  # Forked test workers inherit the run and write files of their own, which
  # `StampSet.load` reads together. The directory gets a `.gitignore` so
  # stamps are never committed.
  class StampStore
    attr_reader :dir, :run

    def initialize(dir, run: ENV.fetch("HALLMARK_RUN") { Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ") })
      @dir = dir.to_s
      @run = run.to_s
      raise ConfigurationError, "a stamp run id cannot contain '-': #{@run}" if @run.include?("-")

      @lock = Mutex.new
      @exit_hook = false
      reset
    end

    def path = File.join(dir, "stamps-#{run}-#{@pid}.jsonl")

    # Queues a Stamp or Unchecked event; never blocks on I/O.
    def record(event)
      @lock.synchronize do
        reset if @pid != Process.pid
        start
      end
      @queue << event
    end

    # Blocks until every queued event is written.
    def flush
      thread = @thread
      return unless thread&.alive? && @pid == Process.pid

      done = Thread::Queue.new
      @queue << done
      done.pop
    end

    private

    # After a fork the parent's flusher thread is gone, and the child writes
    # its own file.
    def reset
      @pid = Process.pid
      @queue = Thread::Queue.new
      @thread = nil
      @seen = Set.new
      @file = nil
    end

    def start
      return if @thread&.alive?

      unless @exit_hook
        @exit_hook = true
        at_exit { flush }
      end
      queue = @queue
      @thread = Thread.new { drain(queue) }
    end

    def drain(queue)
      loop do
        event = queue.pop
        if event.is_a?(Thread::Queue)
          @file&.flush
          event << true
        elsif @seen.add?(event)
          (@file ||= open_file).puts(event.to_json_line)
        end
      end
    end

    def open_file
      FileUtils.mkdir_p(dir)
      ignore = File.join(dir, ".gitignore")
      File.write(ignore, "*\n") unless File.exist?(ignore)
      File.open(path, "a")
    end
  end
end
