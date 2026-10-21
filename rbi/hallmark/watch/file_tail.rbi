# typed: strict

module Hallmark
  class Watch
    class FileTail
      # A stamp directory, or one JSONL file
      sig { returns(String) }
      attr_reader :path

      # The run tailed; nil until one is named or found
      sig { returns(T.nilable(String)) }
      attr_reader :run

      sig { params(path: T.any(String, Pathname), run: T.nilable(String)).void }
      def initialize(path, run: nil)
        @path = T.let(T.unsafe(nil), String)
        @run = T.let(T.unsafe(nil), T.nilable(String))
        @offsets = T.let(T.unsafe(nil), T::Hash[String, Integer])
      end

      sig { returns(T::Boolean) }
      def blocking?; end

      sig { returns(String) }
      def description; end

      sig { returns(T::Array[String]) }
      def poll; end

      private

      sig { returns(T::Array[String]) }
      def files; end

      sig { params(file: String).returns(T::Array[String]) }
      def read(file); end
    end
  end
end
