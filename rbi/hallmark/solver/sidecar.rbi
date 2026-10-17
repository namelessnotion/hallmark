# typed: strict

module Hallmark
  module Solver
    class Sidecar
      PROTOCOL = T.let(T.unsafe(nil), Integer)
      GRACE = T.let(T.unsafe(nil), Integer)

      class Loaded
        sig { returns(ModelBuilder::Model) }
        def model; end

        # The process the model was loaded into
        sig { returns(T.nilable(ChildProcess)) }
        def child; end

        sig { returns(String) }
        def id; end

        sig { params(model: ModelBuilder::Model, child: T.nilable(ChildProcess), id: String).void }
        def initialize(model:, child:, id:); end
      end

      sig { returns(Integer) }
      attr_reader :timeout

      # Processes started so far; more than one means restarts
      sig { returns(Integer) }
      attr_reader :starts

      sig do
        params(config: Configuration, command: T.nilable(T::Array[String]), grace: T.any(Integer, Float)).void
      end
      def initialize(config = Hallmark.configuration, command: nil, grace: GRACE)
        @java = T.let(T.unsafe(nil), String)
        @jar = T.let(T.unsafe(nil), String)
        @alloy_jar = T.let(T.unsafe(nil), String)
        @timeout = T.let(T.unsafe(nil), Integer)
        @sat_solver = T.let(T.unsafe(nil), String)
        @heap = T.let(T.unsafe(nil), Integer)
        @command = T.let(T.unsafe(nil), T.nilable(T::Array[String]))
        @grace = T.let(T.unsafe(nil), T.any(Integer, Float))
        @child = T.let(T.unsafe(nil), T.nilable(ChildProcess))
        @loaded = T.let(T.unsafe(nil), T.nilable(Loaded))
        @starts = T.let(T.unsafe(nil), Integer)
        @next_id = T.let(T.unsafe(nil), Integer)
      end

      sig { returns(T.nilable(T::Boolean)) }
      def available?; end

      sig { returns(T::Array[String]) }
      def command; end

      sig { params(model: ModelBuilder::Model).returns(Receipt) }
      def check(model); end

      sig do
        params(method: String, params: T::Hash[String, T.untyped], wait: T.any(Integer, Float))
          .returns(T::Hash[String, T.untyped])
      end
      def call(method, params = {}, wait: @timeout); end

      sig { returns(T.nilable(Integer)) }
      def pid; end

      sig { returns(T::Boolean) }
      def running?; end

      sig { void }
      def close; end

      private

      # A loaded model, or why the rest of the run is unknown
      sig { params(model: ModelBuilder::Model, catalog: String).returns(T.any(Loaded, String)) }
      def prepare(model, catalog); end

      sig { params(model: ModelBuilder::Model, catalog: String).returns(Loaded) }
      def loaded(model, catalog); end

      sig { void }
      def unload; end

      sig { params(loaded: Loaded, name: String).returns(Receipt::Command) }
      def check_one(loaded, name); end

      sig { params(name: String, result: T::Hash[String, T.untyped]).returns(Receipt::Command) }
      def verdict(name, result); end

      sig { returns(ChildProcess) }
      def start; end

      sig { params(child: ChildProcess).void }
      def handshake(child); end

      sig do
        params(child: ChildProcess, method: String, params: T::Hash[String, T.untyped], wait: T.any(Integer, Float))
          .returns(T::Hash[String, T.untyped])
      end
      def call_child(child, method, params, wait); end

      sig { params(child: ChildProcess, request: String, deadline: Float).returns(T.nilable(String)) }
      def exchange(child, request, deadline); end
    end
  end
end
