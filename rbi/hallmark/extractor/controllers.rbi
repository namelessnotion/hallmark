# typed: strict

module Hallmark
  class Extractor
    class Controllers
      DIRS = T.let(T.unsafe(nil), T::Array[String])
      AUTHORIZE = T.let(T.unsafe(nil), T::Array[Symbol])
      CHECKS = T.let(T.unsafe(nil), T::Array[Symbol])

      class Authorization
        # Nil when the record's class is not known
        sig { returns(T.nilable(String)) }
        def policy; end

        sig { returns(String) }
        def rule; end

        sig { returns(String) }
        def location; end

        sig { params(policy: T.nilable(String), rule: String, location: String).void }
        def initialize(policy:, rule:, location:); end
      end

      class Load
        # :scoped, :unscoped or :unknown
        sig { returns(Symbol) }
        def kind; end

        sig { returns(T.nilable(String)) }
        def model; end

        sig { params(kind: Symbol, model: T.nilable(String)).void }
        def initialize(kind:, model: nil); end
      end
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

        sig { returns(T::Array[Authorization]) }
        def authorizations; end

        # Whether any authorization check runs (authorize, policy_scope, a skip)
        sig { returns(T::Boolean) }
        def checked; end

        sig do
          params(name: String, loading: T.nilable(Symbol), location: T.nilable(String), verify: T.nilable(Symbol),
                 authorizations: T::Array[Authorization], checked: T::Boolean).void
        end
        def initialize(name:, loading: nil, location: nil, verify: nil, authorizations: [], checked: false); end

        sig { returns(T::Boolean) }
        def scoped?; end
      end

      # A record argument, the method it was read in, and the authorize call
      Record = T.type_alias { [Prism::Node, SourceIndex::Method, Prism::CallNode] }

      sig { params(mapping: Mapping, root: String).void }
      def initialize(mapping, root)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @tenant_reader = T.let(T.unsafe(nil), T.nilable(String))
        @resources = T.let(T.unsafe(nil), T::Array[String])
        @tenant_keys = T.let(T.unsafe(nil), T::Hash[String, String])
        @cache = T.let(T.unsafe(nil), T::Hash[String, T.nilable(EntryPoint)])
      end

      sig { params(entry_point: String).returns(T.nilable(EntryPoint)) }
      def fetch(entry_point); end

      private

      sig { params(entry_point: String).returns(T.nilable(EntryPoint)) }
      def read(entry_point); end

      Methods = T.type_alias { T::Array[SourceIndex::Method] }
      Found = T.type_alias { T::Array[[Prism::Node, SourceIndex::Method]] }

      sig { params(method: SourceIndex::Method, call: Prism::CallNode).returns(String) }
      def location(method, call); end

      sig { params(records: T::Array[Record]).returns(T.nilable(String)) }
      def first_location(records); end

      sig { params(action: String, records: T::Array[Record], loads: T::Array[Load]).returns(T::Array[Authorization]) }
      def authorizations(action, records, loads); end

      sig { params(reach: Methods).returns(T::Boolean) }
      def checked?(reach); end

      sig { params(target: T.nilable(Prism::Node)).returns(T::Array[String]) }
      def namespace(target); end

      sig { params(action: String, record: Record, load: Load).returns(Authorization) }
      def authorization(action, record, load); end

      sig { params(args: T::Array[Prism::Node], target: T.nilable(Prism::Node), load: Load).returns(T.nilable(String)) }
      def policy(args, target, load); end

      sig { params(args: T::Array[Prism::Node], key: Symbol).returns(T.nilable(Prism::Node)) }
      def keyword(args, key); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def symbol(node); end

      sig { params(word: String).returns(String) }
      def camelize(word); end

      sig { returns(Load) }
      def unknown; end

      sig { params(node: Prism::CallNode, model: T.nilable(String)).returns(T::Boolean) }
      def scoped_by_keyword?(node, model); end

      sig { params(pair: Prism::AssocNode, key: String).returns(T::Boolean) }
      def tenant_pair?(pair, key); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Boolean) }
      def tenant_reader?(node); end

      sig { params(name: String).returns(T.nilable(String)) }
      def association(name); end

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
               depth: Integer).returns(Load)
      end
      def classify_or(controller, node, method, reach, depth); end

      sig do
        params(controller: String, node: Prism::Node, method: SourceIndex::Method, reach: Methods, depth: Integer)
          .returns(Load)
      end
      def classify(controller, node, method, reach, depth); end

      sig do
        params(controller: String, node: Prism::CallNode, method: SourceIndex::Method, reach: Methods,
               depth: Integer).returns(Load)
      end
      def classify_call(controller, node, method, reach, depth); end

      sig do
        params(controller: String, body: T.nilable(Prism::Node), method: SourceIndex::Method, reach: Methods,
               depth: Integer).returns(Load)
      end
      def classify_statements(controller, body, method, reach, depth); end

      sig { params(controller: String, found: Found, reach: Methods, depth: Integer).returns(Load) }
      def classify_all(controller, found, reach, depth); end

      sig { params(node: Prism::Node, kinds: T::Array[T::Class[Prism::Node]], name: Symbol).returns(T::Array[Prism::Node]) }
      def writes(node, kinds, name); end

      sig { params(loads: T::Array[Load]).returns(Load) }
      def combine(loads); end

      sig { params(controller: String, action: String).returns(T.nilable(Symbol)) }
      def verify(controller, action); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def constant?(node); end
    end
  end
end
