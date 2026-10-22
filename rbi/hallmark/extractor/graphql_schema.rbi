# typed: strict

module Hallmark
  class Extractor
    class GraphqlSchema
      DIRS = T.let(T.unsafe(nil), T::Array[String])
      NODE = T.let(T.unsafe(nil), String)
      NODE_NAMES = T.let(T.unsafe(nil), T::Array[String])
      SCHEMA = T.let(T.unsafe(nil), String)
      INTERFACE = T.let(T.unsafe(nil), String)
      UNION = T.let(T.unsafe(nil), String)
      AUTH_CALLS = T.let(T.unsafe(nil), T::Array[Symbol])
      Lint = DeclarativeTranslator::Lint

      class Type
        sig { returns(String) }
        def name; end

        sig { returns(String) }
        def graphql_name; end

        # :object, :interface or :union
        sig { returns(Symbol) }
        def kind; end

        sig { returns(T.nilable(String)) }
        def resource; end

        sig { returns(Guard) }
        def guard; end

        sig { returns(T.nilable(Guard)) }
        def scope; end

        sig { returns(T::Boolean) }
        def reauthorize; end

        sig { returns(T.nilable(String)) }
        def location; end

        sig do
          params(name: String, graphql_name: String, kind: Symbol, resource: T.nilable(String), guard: Guard,
                 scope: T.nilable(Guard), reauthorize: T::Boolean, location: T.nilable(String)).void
        end
        def initialize(name:, graphql_name:, kind:, resource:, guard:, scope:, reauthorize:, location:); end

        sig { returns(T::Boolean) }
        def checked?; end
      end

      class Field
        # The type it is read on (the implementer, for an interface's field)
        sig { returns(String) }
        def owner; end

        sig { returns(String) }
        def name; end

        sig { returns(String) }
        def graphql_name; end

        sig { returns(T::Array[String]) }
        def targets; end

        # The interface or union it returns, in GraphQL names
        sig { returns(T.nilable(String)) }
        def via; end

        sig { returns(T::Boolean) }
        def list; end

        sig { returns(T::Boolean) }
        def connection; end

        sig { returns(Guard) }
        def guard; end

        sig { returns(T::Array[ChildCheck]) }
        def child_checks; end

        sig { returns(T.nilable(T::Boolean)) }
        def scoped; end

        sig { returns(T::Array[String]) }
        def arguments; end

        sig { returns(T.nilable(String)) }
        def location; end

        sig do
          params(owner: String, name: String, graphql_name: String, targets: T::Array[String], via: T.nilable(String),
                 list: T::Boolean, connection: T::Boolean, guard: Guard, child_checks: T::Array[ChildCheck],
                 scoped: T.nilable(T::Boolean), arguments: T::Array[String], location: T.nilable(String)).void
        end
        def initialize(owner:, name:, graphql_name:, targets:, via:, list:, connection:, guard:, child_checks:, scoped:,
                       arguments:, location:); end

        sig { returns(String) }
        def key; end

        sig { returns(T::Boolean) }
        def scoped?; end
      end

      class ChildCheck
        # :rule, :abilities or :opaque
        sig { returns(Symbol) }
        def kind; end

        # The rule and policy, or the abilities
        sig { returns(T::Array[String]) }
        def names; end

        sig { returns(String) }
        def source; end

        sig { returns(T.nilable(String)) }
        def location; end

        sig do
          params(kind: Symbol, names: T::Array[String], source: String, location: T.nilable(String)).void
        end
        def initialize(kind:, names:, source:, location:); end
      end

      class Target
        sig { returns(String) }
        def name; end

        sig { returns(T::Boolean) }
        def list; end

        sig { returns(T::Boolean) }
        def connection; end

        sig { params(name: String, list: T::Boolean, connection: T::Boolean).void }
        def initialize(name:, list:, connection:); end
      end

      # The names a check's body is read with: the scope's items and context
      Names = T.type_alias { T::Hash[Symbol, T.nilable(String)] }

      sig do
        params(index: SourceIndex, mapping: Mapping, terms: Terms, translator: MethodTranslator,
               policies: Extractor).void
      end
      def initialize(index, mapping, terms:, translator:, policies:)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @terms = T.let(T.unsafe(nil), Terms)
        @translator = T.let(T.unsafe(nil), MethodTranslator)
        @policies = T.let(T.unsafe(nil), Extractor)
        @types = T.let(T.unsafe(nil), T::Hash[String, Type])
        @fields = T.let(T.unsafe(nil), T::Hash[String, T::Array[Field]])
        @implementer_table = T.let(T.unsafe(nil), T.nilable(T::Hash[String, T::Array[String]]))
        @lints = T.let(T.unsafe(nil), T.nilable(T::Array[Lint]))
        @model = T.let(T.unsafe(nil), T.nilable(GraphqlModel))
      end

      sig { returns(T.nilable(String)) }
      def schema; end

      sig { params(operation: Symbol).returns(T.nilable(String)) }
      def root(operation); end

      sig { params(name: String).returns(Type) }
      def type(name); end

      sig { params(name: String).returns(T::Array[Field]) }
      def fields(name); end

      sig { returns(GraphqlModel) }
      def model; end

      sig { params(field: Field, target: String).returns(Guard) }
      def child_guard(field, target); end

      sig { returns(T::Array[Lint]) }
      def lints; end

      # Each mapped type's own `self.scope_items` as a list scope
      sig { returns(T::Array[Extracted]) }
      def lists; end

      sig { params(name: String, resource: String).returns(T.nilable(Extracted)) }
      def list(name, resource); end

      sig { params(name: String).returns(String) }
      def self.camelize(name); end

      private

      sig { params(operation: Symbol).returns(T.nilable(String)) }
      def declared_root(operation); end

      sig { params(name: String).returns(Type) }
      def read_type(name); end

      sig { params(name: String).returns(T.nilable(String)) }
      def resource_for(name); end

      sig { params(name: String).returns(String) }
      def graphql_name_of(name); end

      sig { params(name: String).returns(Symbol) }
      def kind_of(name); end

      sig { params(name: String).returns(T::Boolean) }
      def interface?(name); end

      sig { params(name: String, resource: T.nilable(String)).returns(Guard) }
      def type_guard(name, resource); end

      sig { params(method: SourceIndex::Method).returns(T::Boolean) }
      def authorization_form?(method); end

      sig { params(name: String).returns(T::Array[String]) }
      def abilities_of(name); end

      sig { params(calls: T::Array[SourceIndex::Call]).returns(T::Array[String]) }
      def authorize_symbols(calls); end

      sig do
        params(abilities: T::Array[String], resource: T.nilable(String), location: T.nilable(String)).returns(Guard)
      end
      def ability_guard(abilities, resource, location); end

      sig do
        params(method: SourceIndex::Method, klass: String, resource: T.nilable(String), record: T.nilable(String),
               context: T.nilable(String)).returns(Guard)
      end
      def translate(method, klass, resource, record:, context:); end

      sig { returns(T::Hash[String, String]) }
      def context_aliases; end

      sig { params(guard: Guard).returns(Guard) }
      def without_super(guard); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def param_name(node); end

      sig { params(name: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def scope_guard(name, resource); end

      sig { params(name: String).returns(T::Boolean) }
      def reauthorize?(name); end

      sig { params(name: String).returns(T::Array[Field]) }
      def read_fields(name); end

      sig { params(name: String).returns(T::Array[String]) }
      def interfaces_of(name); end

      sig { params(node: Prism::Node, owner: String).returns(T.nilable(String)) }
      def interface_named(node, owner); end

      sig { params(name: String).returns(T::Array[Field]) }
      def node_fields(name); end

      sig { params(owner: String, name: String, list: T::Boolean, location: T.nilable(String)).returns(Field) }
      def node_field(owner, name, list, location); end

      sig { params(call: SourceIndex::Call, owner: String).returns(T.nilable(Field)) }
      def read_field(call, owner); end

      sig { params(call: SourceIndex::Call, name: String).returns(String) }
      def field_graphql_name(call, name); end

      sig { params(call: SourceIndex::Call, resolver: T.nilable(String)).returns(T.nilable(Target)) }
      def field_target(call, resolver); end

      sig { params(node: Prism::Node, owner: String).returns(T.nilable(Target)) }
      def type_expression(node, owner); end

      sig { params(node: Prism::CallNode, owner: String).returns(T.nilable(Target)) }
      def type_call(node, owner); end

      sig { params(node: T.nilable(Prism::Node), owner: String).returns(T.nilable(String)) }
      def class_named(node, owner); end

      sig { params(name: String).returns(String) }
      def host_of(name); end

      sig { params(name: String).returns([T::Array[String], T.nilable(String)]) }
      def targets_of(name); end

      sig { params(interface: String).returns(T::Array[String]) }
      def implementers(interface); end

      sig { returns(T::Hash[String, T::Array[String]]) }
      def implementer_table; end

      sig { params(name: String).returns(T::Array[String]) }
      def implemented(name); end

      sig { params(name: String).returns(T::Array[String]) }
      def union_members(name); end

      sig { params(call: SourceIndex::Call).returns(T.nilable(String)) }
      def resolver_of(call); end

      sig { params(resolver: String).returns(T.nilable(Target)) }
      def resolver_type(resolver); end

      sig { params(call: SourceIndex::Call, owner: String, resolver: T.nilable(String)).returns(Guard) }
      def field_guard(call, owner, resolver); end

      sig { params(call: SourceIndex::Call, owner: String, resource: T.nilable(String)).returns(Guard) }
      def block_guard(call, owner, resource); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Array[String]) }
      def gitlab_abilities(node); end

      sig { params(resolver: String).returns(T::Boolean) }
      def authorizes_object?(resolver); end

      sig { params(method: T.nilable(SourceIndex::Method)).returns(T::Boolean) }
      def literal_true?(method); end

      sig { params(resolver: String).returns(T::Array[String]) }
      def resolver_abilities(resolver); end

      sig { params(call: SourceIndex::Call, resolver: T.nilable(String)).returns(T::Array[ChildCheck]) }
      def child_checks(call, resolver); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def action_policy?(node); end

      sig { params(node: Prism::Node, location: String).returns(ChildCheck) }
      def action_policy_check(node, location); end

      sig do
        params(hash: T.any(Prism::HashNode, Prism::KeywordHashNode), key: String).returns(T.nilable(Prism::Node))
      end
      def pair_value(hash, key); end

      sig { params(resolver: String).returns(T::Array[ChildCheck]) }
      def resolver_child_checks(resolver); end

      sig { params(check: ChildCheck, resource: T.nilable(String)).returns(Guard) }
      def child_check_guard(check, resource); end

      sig { params(call: SourceIndex::Call).returns(T.nilable(T::Boolean)) }
      def scoped_option(call); end

      sig { params(call: SourceIndex::Call, resolver: T.nilable(String)).returns(T::Array[String]) }
      def field_arguments(call, resolver); end

      sig { params(node: Prism::CallNode).returns(T.nilable(String)) }
      def required_argument(node); end

      sig { params(node: Prism::CallNode).returns(T::Array[Prism::CallNode]) }
      def block_calls(node); end

      sig { returns(T::Array[Lint]) }
      def mutation_lints; end

      sig { returns(T::Array[[String, SourceIndex::Call]]) }
      def mutations; end

      sig { params(call: SourceIndex::Call).returns(T.nilable(Prism::Node)) }
      def mutation_node(call); end

      sig { params(mutation: String, call: SourceIndex::Call).returns(T::Array[Lint]) }
      def mutation_hazards(mutation, call); end

      sig { params(mutation: String).returns(T::Boolean) }
      def mutation_checked?(mutation); end

      sig { params(name: String).returns(T::Array[String]) }
      def own_ancestors(name); end

      sig { params(klass: String, node: Prism::Node, depth: Integer).returns(T::Boolean) }
      def authorizes_in?(klass, node, depth); end

      sig { params(node: Prism::Node, names: T::Array[Symbol]).returns(T::Boolean) }
      def calls_any?(node, names); end

      sig { params(node: Prism::Node).returns(T::Array[Prism::CallNode]) }
      def calls(node); end

      sig { params(mutation: String).returns(T::Array[Lint]) }
      def load_hazards(mutation); end

      sig { params(mutation: String, method: SourceIndex::Method).returns(T::Boolean) }
      def skips_nothing?(mutation, method); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def contains_super?(node); end

      sig { returns(T::Array[Lint]) }
      def scope_lints; end

      sig { params(call: SourceIndex::Call).returns(T::Boolean) }
      def unscoped_list?(call); end

      sig { params(name: String).returns(T::Array[Lint]) }
      def reauthorize_lints(name); end

      sig do
        params(call: T.any(SourceIndex::Call, Prism::CallNode), key: T.any(Symbol, String)).returns(T.nilable(Prism::Node))
      end
      def keyword(call, key); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def symbol(node); end
    end
  end
end
