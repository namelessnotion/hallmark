# typed: strict

module Hallmark
  class StampStore
    class Pending
      sig { returns(Stamp) }
      def stamp; end

      sig { returns(Example) }
      def example; end

      sig { params(stamp: Stamp, example: Example).void }
      def initialize(stamp, example); end
    end

    # A Stamp, Unchecked or Route waiting to be written (a stamp with its
    # ids), or a queue to signal once everything before it is written
    Event = T.type_alias { T.any(Stamp, Unchecked, Route, ContextMismatch, Pending, Thread::Queue) }

    sig { returns(String) }
    attr_reader :dir

    sig { returns(String) }
    attr_reader :run

    sig { returns(T.nilable(Integer)) }
    attr_reader :capacity

    # Events `record` dropped because the queue was full.
    sig { returns(Integer) }
    attr_reader :dropped

    # Lines the sink failed to write
    sig { returns(Integer) }
    attr_reader :failed

    sig { returns(Sinks::Sink) }
    attr_reader :sink

    sig do
      params(dir: T.any(String, Pathname), run: T.any(String, Symbol), capacity: T.nilable(Integer),
             sink: T.untyped, id_key: T.nilable(String)).void
    end
    def initialize(dir, run: ENV.fetch("HALLMARK_RUN") { Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ") }, capacity: nil,
                   sink: nil, id_key: nil)
      @dir = T.let(T.unsafe(nil), String)
      @run = T.let(T.unsafe(nil), String)
      @capacity = T.let(T.unsafe(nil), T.nilable(Integer))
      @dropped = T.let(T.unsafe(nil), Integer)
      @failed = T.let(T.unsafe(nil), Integer)
      @sink = T.let(T.unsafe(nil), Sinks::Sink)
      @id_key = T.let(T.unsafe(nil), T.nilable(String))
      @warned = T.let(T.unsafe(nil), T::Hash[String, T::Boolean])
      @lock = T.let(T.unsafe(nil), Thread::Mutex)
      @exit_hook = T.let(T.unsafe(nil), T::Boolean)
      @pid = T.let(T.unsafe(nil), Integer)
      @queue = T.let(T.unsafe(nil), Thread::Queue)
      @thread = T.let(T.unsafe(nil), T.nilable(Thread))
      @seen = T.let(T.unsafe(nil), T::Set[T.any(Stamp, Unchecked, Route, ContextMismatch)])
    end

    # The default file sink's file for this process; nil with another sink
    sig { returns(T.nilable(String)) }
    def path; end

    sig { returns(T::Boolean) }
    def ids?; end

    sig { params(event: T.any(Stamp, Unchecked, Route, ContextMismatch), example: T.nilable(Example)).void }
    def record(event, example: nil); end

    sig { void }
    def flush; end

    private

    sig { void }
    def reset; end

    sig { void }
    def start; end

    sig { params(queue: Thread::Queue).void }
    def drain(queue); end

    sig { params(event: T.any(Stamp, Unchecked, Route, ContextMismatch, Pending)).void }
    def write(event); end

    sig { params(blk: T.proc.void).void }
    def guarded(&blk); end
  end
end
