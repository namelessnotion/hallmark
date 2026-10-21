# typed: strict

module Hallmark
  class Watch
    class RedisTail
      COUNT = T.let(T.unsafe(nil), Integer)

      # A redis-rb or redis-client connection
      sig { returns(T.untyped) }
      attr_reader :client

      sig { returns(String) }
      attr_reader :stream

      sig { returns(T.nilable(String)) }
      attr_reader :run

      sig { params(url: String).returns(T.untyped) }
      def self.connect(url); end

      sig do
        params(client: T.untyped, stream: String, run: T.nilable(String), all_runs: T::Boolean,
               from_start: T::Boolean, block: T.nilable(Integer)).void
      end
      def initialize(client, stream: T.unsafe(nil), run: nil, all_runs: false, from_start: false, block: nil)
        @client = T.let(T.unsafe(nil), T.untyped)
        @stream = T.let(T.unsafe(nil), String)
        @run = T.let(T.unsafe(nil), T.nilable(String))
        @all_runs = T.let(T.unsafe(nil), T::Boolean)
        @block = T.let(T.unsafe(nil), T.nilable(Integer))
        @last_id = T.let(T.unsafe(nil), T.nilable(String))
      end

      sig { returns(T::Boolean) }
      def blocking?; end

      sig { returns(String) }
      def description; end

      sig { returns(T::Array[String]) }
      def poll; end

      private

      sig { params(block: T.nilable(Integer)).returns(T::Array[[String, T::Hash[String, T.untyped]]]) }
      def read(block); end

      sig { returns(String) }
      def last_entry_id; end

      sig { params(result: T.untyped).returns(T::Array[[String, T::Hash[String, T.untyped]]]) }
      def entries(result); end

      sig { params(fields: T.untyped).returns(T::Hash[String, T.untyped]) }
      def field_hash(fields); end
    end
  end
end
