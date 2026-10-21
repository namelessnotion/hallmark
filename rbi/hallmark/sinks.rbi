# typed: strict

module Hallmark
  module Sinks
    # Anything with `write(line, run)`; `flush` and `after_fork` are optional
    Sink = T.type_alias { T.untyped }

    class File
      sig { returns(String) }
      attr_reader :dir

      sig { params(dir: T.any(String, Pathname)).void }
      def initialize(dir)
        @dir = T.let(T.unsafe(nil), String)
        @file = T.let(T.unsafe(nil), T.nilable(::File))
      end

      sig { params(run: String).returns(String) }
      def path(run); end

      sig { params(line: String, run: String).void }
      def write(line, run); end

      sig { void }
      def flush; end

      sig { void }
      def after_fork; end

      private

      sig { params(run: String).returns(::File) }
      def open_file(run); end
    end

    class RedisStream
      DEFAULT_STREAM = T.let(T.unsafe(nil), String)
      DEFAULT_MAXLEN = T.let(T.unsafe(nil), Integer)

      # A redis-rb or redis-client connection
      sig { returns(T.untyped) }
      attr_reader :client

      sig { returns(String) }
      attr_reader :stream

      sig { returns(Integer) }
      attr_reader :maxlen

      sig { params(client: T.untyped, stream: T.any(String, Symbol), maxlen: Integer).void }
      def initialize(client, stream: DEFAULT_STREAM, maxlen: DEFAULT_MAXLEN)
        @client = T.let(T.unsafe(nil), T.untyped)
        @stream = T.let(T.unsafe(nil), String)
        @maxlen = T.let(T.unsafe(nil), Integer)
      end

      sig { params(line: String, run: String).void }
      def write(line, run); end
    end

    class Callable
      sig { params(callable: T.untyped).void }
      def initialize(callable)
        @callable = T.let(T.unsafe(nil), T.untyped)
      end

      sig { params(line: String, run: String).void }
      def write(line, run); end
    end

    sig { params(value: T.untyped).returns(T.untyped) }
    def self.build(value); end
  end
end
