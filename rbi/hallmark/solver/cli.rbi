# typed: strict

module Hallmark
  module Solver
    class CLI
      sig { returns(String) }
      attr_reader :jar

      sig { returns(String) }
      attr_reader :java

      sig { returns(Integer) }
      attr_reader :timeout

      sig { returns(String) }
      attr_reader :solver

      sig { params(config: Configuration).void }
      def initialize(config = Hallmark.configuration)
        @jar = T.let(T.unsafe(nil), String)
        @java = T.let(T.unsafe(nil), String)
        @timeout = T.let(T.unsafe(nil), Integer)
        @solver = T.let(T.unsafe(nil), String)
      end

      # Process::Status#success? is nil when the process did not exit normally.
      sig { returns(T.nilable(T::Boolean)) }
      def available?; end

      sig { params(model: ModelBuilder::Model).returns(Receipt) }
      def check(model); end

      sig { void }
      def close; end

      sig { params(model: ModelBuilder::Model, output: String).returns(Receipt) }
      def solve_into(model, output); end

      private

      sig { params(model_path: String, output: String).returns(T::Array[String]) }
      def command(model_path, output); end

      # T.untyped because Sorbet rejects splatting an array of unknown length.
      sig { params(cmd: T.untyped).returns([String, String, Process::Status]) }
      def run(cmd); end

      sig { params(pipe: IO).returns(String) }
      def drain(pipe); end
    end
  end
end
