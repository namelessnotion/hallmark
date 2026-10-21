# typed: strict
# frozen_string_literal: true

module Hallmark
  # Writes stamps off the request thread. `record` only pushes the event onto
  # a queue; a flusher thread dedupes events into stamps and writes each new
  # one, as a JSON line, to the sink: by default one JSONL file per process,
  #
  #   tmp/hallmark/stamps-<run>-<pid>.jsonl
  #
  # or a Redis stream or a callable (`Sinks`). Forked workers inherit the
  # run and write files of their own, which `StampSet.load` reads together.
  #
  # With a `capacity`, at most that many events wait for the flusher, and
  # `record` drops (and counts) an event rather than wait or let the queue
  # grow; without one, as in test mode, nothing is dropped. The set of
  # stamps already written is cleared once it holds SEEN_LIMIT, which only
  # lets a later duplicate be written again (`StampSet` dedupes on reading).
  #
  # With an `id_key`, a stamp may be recorded with an Example of the ids it
  # was seen with; the first time the process writes that stamp, the
  # example is hashed with the key and written beside it (docs/adr/0004).
  # A sink that raises loses that line, counted in `failed`, and warns once
  # per kind of error; the flusher carries on.
  class StampStore
    SEEN_LIMIT = 100_000

    # A stamp waiting with the ids it was seen with.
    Pending = Struct.new(:stamp, :example)

    attr_reader :dir, :run, :capacity, :dropped, :failed, :sink

    def initialize(dir, run: ENV.fetch("HALLMARK_RUN") { Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ") }, capacity: nil,
                   sink: nil, id_key: nil)
      @dir = dir.to_s
      @run = run.to_s
      raise ConfigurationError, "a stamp run id cannot contain '-': #{@run}" if @run.include?("-")
      if capacity && !capacity.positive?
        raise ConfigurationError, "a stamp store's capacity must be a positive Integer, not #{capacity.inspect}"
      end

      @capacity = capacity
      @sink = Sinks.build(sink) || Sinks::File.new(@dir)
      @id_key = id_key
      @dropped = 0
      @failed = 0
      @warned = {}
      @lock = Mutex.new
      @exit_hook = false
      reset
    end

    # The file this process writes, when the sink is the default file.
    def path
      sink = @sink
      sink.path(run) if sink.is_a?(Sinks::File)
    end

    # Whether stamps are recorded with hashed ids.
    def ids? = !@id_key.nil?

    # Queues a Stamp, Unchecked or Route event, with the ids a stamp was
    # seen with when `ids?`; never blocks on I/O, and with a capacity never
    # waits for the flusher either.
    def record(event, example: nil)
      @lock.synchronize do
        reset if @pid != Process.pid
        start
      end
      event = Pending.new(event, example) if example && @id_key && event.is_a?(Stamp)
      queue = @queue
      return queue << event unless queue.is_a?(Thread::SizedQueue)

      queue.push(event, true)
    rescue ThreadError
      @lock.synchronize { @dropped += 1 }
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
    # through the sink on its own (its own file, for the default).
    def reset
      @pid = Process.pid
      @queue = @capacity ? Thread::SizedQueue.new(@capacity) : Thread::Queue.new
      @thread = nil
      @seen = Set.new
      sink = @sink
      sink.after_fork if sink.respond_to?(:after_fork)
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
          guarded { @sink.flush if @sink.respond_to?(:flush) }
          event << true
        else
          guarded { write(event) }
        end
      end
    end

    def write(event)
      example = nil
      if event.is_a?(Pending)
        example = event.example
        event = event.stamp
      end
      return unless @seen.add?(event)

      key = @id_key
      line = event.is_a?(Stamp) && example && key ? event.to_json_line(example.hashed(key)) : event.to_json_line
      @sink.write(line, run)
      @seen.clear if @seen.size >= SEEN_LIMIT
    end

    def guarded
      yield
    rescue StandardError => e
      @failed += 1
      message = "#{e.class}: #{e.message}"
      return if @warned[message]

      @warned[message] = true
      Kernel.warn("hallmark: the stamp sink failed: #{message}")
    end
  end
end
