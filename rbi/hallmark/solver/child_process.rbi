# typed: strict

module Hallmark
  module Solver
    class ChildProcess
      STDERR_KEPT = T.let(T.unsafe(nil), Integer)

      sig { params(command: T::Array[String]).returns(ChildProcess) }
      def self.spawn(command); end

      sig { params(command: T.untyped).returns([IO, IO, IO, Process::Waiter]) }
      def self.popen(command); end

      sig { returns(Float) }
      def self.now; end

      sig { params(stdin: IO, stdout: IO, stderr: IO, wait: Process::Waiter).void }
      def initialize(stdin, stdout, stderr, wait)
        @stdin = T.let(T.unsafe(nil), IO)
        @stdout = T.let(T.unsafe(nil), IO)
        @wait = T.let(T.unsafe(nil), Process::Waiter)
        @output = T.let(T.unsafe(nil), String)
        @errors = T.let(T.unsafe(nil), String)
        @reader = T.let(T.unsafe(nil), Thread)
      end

      sig { returns(Integer) }
      def pid; end

      sig { params(line: String).void }
      def write_line(line); end

      sig { params(deadline: Float).returns(T.nilable(String)) }
      def read_line(deadline); end

      sig { params(seconds: T.any(Integer, Float)).returns(T.nilable(Process::Status)) }
      def finish(seconds = 2); end

      sig { returns(T.nilable(Process::Status)) }
      def kill; end

      sig { returns(Crash) }
      def crash; end

      sig { params(lines: Integer).returns(String) }
      def errors_tail(lines = 5); end

      private

      sig { returns(T.nilable(Process::Status)) }
      def reap; end

      sig { params(stderr: IO).void }
      def drain(stderr); end
    end
  end
end
