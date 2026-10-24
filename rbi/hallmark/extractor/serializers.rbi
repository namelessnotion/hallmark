# typed: strict

module Hallmark
  class Extractor
    class Serializers
      DIRS = T.let(T.unsafe(nil), T::Array[String])
      GRAPE = T.let(T.unsafe(nil), String)
      AMS = T.let(T.unsafe(nil), String)
      JBUILDER = T.let(T.unsafe(nil), String)

      class Condition
        # :lambda, :option, :options, :method or :opaque
        sig { returns(Symbol) }
        def kind; end

        sig { returns(Prism::Node) }
        def node; end

        sig { returns(T::Boolean) }
        def negated; end

        # The class or module whose body declares it
        sig { returns(String) }
        def owner; end

        sig { returns(String) }
        def file; end

        sig { params(kind: Symbol, node: Prism::Node, negated: T::Boolean, owner: String, file: String).void }
        def initialize(kind:, node:, negated:, owner:, file:); end
      end

      class Shown
        sig { returns(String) }
        def serializer; end

        sig { returns(String) }
        def name; end

        sig { returns(String) }
        def key; end

        sig { returns(T::Array[Condition]) }
        def conditions; end

        sig { returns(String) }
        def location; end

        # The nested serializer as written; nil when it names none
        sig { returns(T.nilable(String)) }
        def nested; end

        sig { returns(T::Array[String]) }
        def namespace; end

        sig { returns(T::Boolean) }
        def association; end

        sig do
          params(serializer: String, name: String, key: String, conditions: T::Array[Condition], location: String,
                 nested: T.nilable(String), namespace: T::Array[String], association: T::Boolean).void
        end
        def initialize(serializer:, name:, key:, conditions:, location:, nested:, namespace:, association:); end
      end

      class Field
        sig { returns(String) }
        def serializer; end

        sig { returns(String) }
        def name; end

        sig { returns(String) }
        def key; end

        sig { returns(Guard) }
        def condition; end

        sig { returns(String) }
        def location; end

        # The mapped resource of a nested record; nil for a field
        sig { returns(T.nilable(String)) }
        def resource; end

        sig do
          params(serializer: String, name: String, key: String, condition: Guard, location: String,
                 resource: T.nilable(String)).void
        end
        def initialize(serializer:, name:, key:, condition:, location:, resource:); end

        sig { returns(T::Boolean) }
        def nested?; end

        # "Serializer#field (file:line)"
        sig { returns(String) }
        def shown_by; end
      end

      class Rendering
        # :rails or :grape
        sig { returns(Symbol) }
        def kind; end

        sig { returns(T.nilable(String)) }
        def serializer; end

        sig { returns(T::Boolean) }
        def default; end

        sig { returns(T::Array[String]) }
        def namespace; end

        sig { returns(Prism::Node) }
        def expression; end

        sig { returns(String) }
        def source; end

        sig { returns(T::Boolean) }
        def collection; end

        sig { returns(T::Hash[String, Prism::Node]) }
        def options; end

        sig { returns(Locals) }
        def locals; end

        sig { returns(T::Array[Branch]) }
        def branches; end

        sig { returns(String) }
        def location; end

        # The serialization scope's reader (AMS); nil after `serialization_scope nil` or in Grape
        sig { returns(T.nilable(String)) }
        def scope; end

        sig { returns(String) }
        def user_reader; end

        sig { returns(T.nilable(String)) }
        def model; end

        sig { returns(T.nilable(Controllers::Authorization)) }
        def authorization; end

        sig { returns(T::Array[Controllers::Authorization]) }
        def candidates; end

        sig { returns(T.nilable(String)) }
        def unknown; end

        sig do
          params(kind: Symbol, serializer: T.nilable(String), default: T::Boolean, namespace: T::Array[String],
                 expression: Prism::Node, source: String, collection: T::Boolean,
                 options: T::Hash[String, Prism::Node], locals: Locals, branches: T::Array[Branch], location: String,
                 scope: T.nilable(String), user_reader: String, model: T.nilable(String),
                 authorization: T.nilable(Controllers::Authorization),
                 candidates: T::Array[Controllers::Authorization], unknown: T.nilable(String)).void
        end
        def initialize(kind:, serializer:, default:, namespace:, expression:, source:, collection:, options:, locals:,
                       branches:, location:, scope:, user_reader:, model:, authorization:, candidates:, unknown:); end

        # The rendered expression as written
        sig { returns(String) }
        def text; end
      end

      class Branch
        sig { returns(Prism::Node) }
        def node; end

        sig { returns(T::Boolean) }
        def negated; end

        sig { returns(T.nilable(SourceIndex::Method)) }
        def definition; end

        sig { returns(String) }
        def klass; end

        sig { returns(String) }
        def file; end

        sig { returns(Locals) }
        def locals; end

        sig do
          params(node: Prism::Node, negated: T::Boolean, definition: T.nilable(SourceIndex::Method), klass: String,
                 file: String, locals: Locals).void
        end
        def initialize(node:, negated:, definition:, klass:, file:, locals:); end
      end

      class Context
        sig { returns(T.nilable(String)) }
        def resource; end

        sig { returns(T.nilable(Rendering)) }
        def rendering; end

        sig { returns(String) }
        def serializer; end

        sig { params(resource: T.nilable(String), rendering: T.nilable(Rendering), serializer: String).void }
        def initialize(resource:, rendering:, serializer:); end
      end

      sig do
        params(mapping: Mapping, root: String, dirs: T::Array[String], terms: Terms, policies: Extractor).void
      end
      def initialize(mapping, root, dirs, terms:, policies:)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @root = T.let(T.unsafe(nil), String)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @translator = T.let(T.unsafe(nil), MethodTranslator)
        @user = T.let(T.unsafe(nil), String)
        @conditions = T.let(T.unsafe(nil), Conditions)
        @shown = T.let(T.unsafe(nil), T::Hash[String, T::Array[Shown]])
        @grape = T.let(T.unsafe(nil), GrapeEntity)
        @active_model = T.let(T.unsafe(nil), ActiveModel)
        @serializers = T.let(T.unsafe(nil), T.nilable(T::Array[String]))
      end

      sig { returns(T::Array[String]) }
      def serializers; end

      # :grape or :active_model
      sig { params(name: String).returns(T.nilable(Symbol)) }
      def dialect(name); end

      sig { params(name: String).returns(T::Array[Shown]) }
      def shown(name); end

      sig { params(rendering: Rendering, resource: T.nilable(String)).returns(T.nilable(String)) }
      def resolve(rendering, resource = nil); end

      sig { params(name: String).returns(T.nilable(String)) }
      def resource_of(name); end

      sig { params(name: String, resource: T.nilable(String), rendering: T.nilable(Rendering)).returns(T::Array[Field]) }
      def fields(name, resource, rendering = nil); end

      sig do
        params(condition: Condition, resource: T.nilable(String), rendering: T.nilable(Rendering), serializer: String)
          .returns(Guard)
      end
      def condition_guard(condition, resource, rendering = nil, serializer: condition.owner); end

      sig { params(branch: Branch, resource: String).returns(Guard) }
      def branch_guard(branch, resource); end

      sig { returns(Integer) }
      def jbuilder_views; end

      sig { params(call: Prism::CallNode).returns(T::Array[String]) }
      def self.names(call); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def self.literal_name(node); end

      sig { params(call: Prism::CallNode).returns(T::Hash[String, Prism::Node]) }
      def self.keywords(call); end

      sig { params(hash: T.nilable(Prism::Node)).returns(T::Hash[String, Prism::Node]) }
      def self.pairs(hash); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def self.constant_text(node); end

      # [parameter names, body]
      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable([T::Array[String], T.nilable(Prism::Node)])) }
      def self.lambda_parts(node); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Array[String]) }
      def self.parameter_names(node); end

      sig { params(prefix: T.nilable(String), name: String).returns(String) }
      def self.join(prefix, name); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Array[Prism::Node]) }
      def self.statements(node); end

      private

      sig { params(written: String, namespace: T::Array[String]).returns(T.nilable(String)) }
      def serializer_named(written, namespace); end

      sig { params(name: String).returns(T.nilable(String)) }
      def named_resource(name); end

      sig { params(shown: Shown).returns(T.nilable(String)) }
      def nested_resource(shown); end

      sig { params(name: String).returns(String) }
      def singular(name); end
    end
  end
end
