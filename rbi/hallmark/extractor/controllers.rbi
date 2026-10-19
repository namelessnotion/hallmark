# typed: strict

module Hallmark
  class Extractor
    class Controllers
      DIRS = T.let(T.unsafe(nil), T::Array[String])
      AUTHORIZE = T.let(T.unsafe(nil), T::Array[Symbol])
      VERIFY = T.let(T.unsafe(nil), String)
      DEPTH = T.let(T.unsafe(nil), Integer)
      LOCAL_WRITES = T.let(T.unsafe(nil), T::Array[T::Class[Prism::Node]])
      IVAR_WRITES = T.let(T.unsafe(nil), T::Array[T::Class[Prism::Node]])

      class EntryPoint
        sig { returns(String) }
        def name; end

        # :scoped, :unscoped or :unknown; nil when no record is authorized
        sig { returns(T.nilable(Symbol)) }
        def loading; end

        sig { returns(T.nilable(String)) }
        def location; end

        # :required, :skipped, or nil when the app never declares verify_authorized
        sig { returns(T.nilable(Symbol)) }
        def verify; end

        sig do
          params(name: String, loading: T.nilable(Symbol), location: T.nilable(String), verify: T.nilable(Symbol)).void
        end
        def initialize(name:, loading: nil, location: nil, verify: nil); end

        sig { returns(T::Boolean) }
        def scoped?; end
      end

      # A record argument, the method it was read in, and the authorize call
      Record = T.type_alias { [Prism::Node, SourceIndex::Method, Prism::CallNode] }

      sig { params(mapping: Mapping, root: String).void }
      def initialize(mapping, root)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @tenant_reader = T.let(T.unsafe(nil), T.nilable(String))
        @cache = T.let(T.unsafe(nil), T::Hash[String, T.nilable(EntryPoint)])
      end

      sig { params(entry_point: String).returns(T.nilable(EntryPoint)) }
      def fetch(entry_point); end

      private

      sig { params(entry_point: String).returns(T.nilable(EntryPoint)) }
      def read(entry_point); end

      Methods = T.type_alias { T::Array[SourceIndex::Method] }
      Found = T.type_alias { T::Array[[Prism::Node, SourceIndex::Method]] }

      sig { params(controller: String, records: T::Array[Record], reach: Methods).returns(T.nilable(Symbol)) }
      def loading(controller, records, reach); end

      sig { params(controller: String, action: String).returns(Methods) }
      def run_methods(controller, action); end

      sig { params(names: T::Array[String], callback: SourceIndex::Callback).returns(T::Array[String]) }
      def add_callback(names, callback); end

      sig { params(controller: String, methods: Methods).returns(Methods) }
      def reachable(controller, methods); end

      sig { params(node: Prism::Node).returns(T::Array[Prism::CallNode]) }
      def calls(node); end

      sig { params(reach: Methods).returns(T::Array[Record]) }
      def records_in(reach); end

      sig { params(call: Prism::CallNode).returns(T.nilable(Prism::Node)) }
      def record_of(call); end

      sig do
        params(controller: String, node: Prism::OrNode, method: SourceIndex::Method, reach: Methods,
               depth: Integer).returns(Symbol)
      end
      def classify_or(controller, node, method, reach, depth); end

      sig do
        params(controller: String, node: Prism::Node, method: SourceIndex::Method, reach: Methods, depth: Integer)
          .returns(Symbol)
      end
      def classify(controller, node, method, reach, depth); end

      sig do
        params(controller: String, node: Prism::CallNode, method: SourceIndex::Method, reach: Methods,
               depth: Integer).returns(Symbol)
      end
      def classify_call(controller, node, method, reach, depth); end

      sig do
        params(controller: String, body: T.nilable(Prism::Node), method: SourceIndex::Method, reach: Methods,
               depth: Integer).returns(Symbol)
      end
      def classify_statements(controller, body, method, reach, depth); end

      sig { params(controller: String, found: Found, reach: Methods, depth: Integer).returns(Symbol) }
      def classify_all(controller, found, reach, depth); end

      sig { params(node: Prism::Node, kinds: T::Array[T::Class[Prism::Node]], name: Symbol).returns(T::Array[Prism::Node]) }
      def writes(node, kinds, name); end

      sig { params(kinds: T::Array[Symbol]).returns(Symbol) }
      def combine(kinds); end

      sig { params(controller: String, action: String).returns(T.nilable(Symbol)) }
      def verify(controller, action); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def constant?(node); end
    end
  end
end
