# typed: strict

module Hallmark
  class StampStore
    # A Stamp, Unchecked or Route waiting to be written, or a queue to signal once
    # everything before it is written
    Event = T.type_alias { T.any(Stamp, Unchecked, Route, Thread::Queue) }

    sig { returns(String) }
    attr_reader :dir

    sig { returns(String) }
    attr_reader :run

    sig { returns(T.nilable(Integer)) }
    attr_reader :capacity

    # Events `record` dropped because the queue was full.
    sig { returns(Integer) }
    attr_reader :dropped

    sig { params(dir: T.any(String, Pathname), run: T.any(String, Symbol), capacity: T.nilable(Integer)).void }
    def initialize(dir, run: ENV.fetch("HALLMARK_RUN") { Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ") }, capacity: nil)
      @dir = T.let(T.unsafe(nil), String)
      @run = T.let(T.unsafe(nil), String)
      @capacity = T.let(T.unsafe(nil), T.nilable(Integer))
      @dropped = T.let(T.unsafe(nil), Integer)
      @lock = T.let(T.unsafe(nil), Thread::Mutex)
      @exit_hook = T.let(T.unsafe(nil), T::Boolean)
      @pid = T.let(T.unsafe(nil), Integer)
      @queue = T.let(T.unsafe(nil), Thread::Queue)
      @thread = T.let(T.unsafe(nil), T.nilable(Thread))
      @seen = T.let(T.unsafe(nil), T::Set[T.any(Stamp, Unchecked, Route)])
      @file = T.let(T.unsafe(nil), T.nilable(File))
    end

    sig { returns(String) }
    def path; end

    sig { params(event: T.any(Stamp, Unchecked, Route)).void }
    def record(event); end

    sig { void }
    def flush; end

    private

    sig { void }
    def reset; end

    sig { void }
    def start; end

    sig { params(queue: Thread::Queue).void }
    def drain(queue); end

    sig { returns(File) }
    def open_file; end
  end
end
