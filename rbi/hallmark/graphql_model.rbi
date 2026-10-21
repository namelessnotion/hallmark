# typed: strict

module Hallmark
  class GraphqlModel
    MAX_UNMAPPED = T.let(T.unsafe(nil), Integer)
    SHOWN = T.let(T.unsafe(nil), Integer)
    RECORD_KINDS = T.let(T.unsafe(nil), T::Array[Symbol])

    class Step
      sig { returns(Extractor::GraphqlSchema::Field) }
      def field; end

      sig { returns(String) }
      def target; end

      sig { params(field: Extractor::GraphqlSchema::Field, target: String).void }
      def initialize(field:, target:); end
    end

    class Edge
      # The parent type; nil for a root entry
      sig { returns(T.nilable(String)) }
      def parent; end

      sig { returns(T::Array[Step]) }
      def steps; end

      sig { returns(String) }
      def child; end

      sig { returns(Guard) }
      def guard; end

      sig { returns(Guard) }
      def entry; end

      sig { returns(T::Array[String]) }
      def through; end

      sig { returns(T::Array[String]) }
      def unread; end

      sig { returns(T.nilable(String)) }
      def relation; end

      sig { params(relation: T.nilable(String)).returns(T.nilable(String)) }
      def relation=(relation); end

      sig do
        params(parent: T.nilable(String), steps: T::Array[Step], child: String, guard: Guard, entry: Guard,
               through: T::Array[String], unread: T::Array[String], relation: T.nilable(String)).void
      end
      def initialize(parent:, steps:, child:, guard:, entry:, through:, unread:, relation: nil); end

      sig { returns(String) }
      def path; end

      sig { returns(T::Boolean) }
      def collapsed?; end
    end

    sig { returns(Extractor::GraphqlSchema) }
    attr_reader :schema

    sig { returns(T::Array[Edge]) }
    attr_reader :roots

    sig { returns(T::Array[Edge]) }
    attr_reader :edges

    sig { returns(T::Array[Edge]) }
    attr_reader :unmodeled

    sig { returns(T::Array[String]) }
    attr_reader :types

    sig { returns(Integer) }
    attr_reader :cut

    sig { params(mapping: Mapping, schema: Extractor::GraphqlSchema).void }
    def initialize(mapping, schema)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @schema = T.let(T.unsafe(nil), Extractor::GraphqlSchema)
      @roots = T.let(T.unsafe(nil), T::Array[Edge])
      @edges = T.let(T.unsafe(nil), T::Array[Edge])
      @unmodeled = T.let(T.unsafe(nil), T::Array[Edge])
      @types = T.let(T.unsafe(nil), T::Array[String])
      @cut = T.let(T.unsafe(nil), Integer)
      @checks = T.let(T.unsafe(nil), T.nilable(T::Array[GraphqlCheck]))
      @alloy = T.let(T.unsafe(nil), Alloy)
    end

    sig { returns(T::Array[Extractor::DeclarativeTranslator::Lint]) }
    def lints; end

    sig { returns(T::Array[GraphqlCheck]) }
    def checks; end

    sig { returns(T::Array[String]) }
    def resources; end

    sig { params(resource: String).returns(T::Array[String]) }
    def relations_of(resource); end

    sig { returns(T::Array[[Guard, String]]) }
    def guards; end

    sig { params(tenancy: T::Boolean).returns(String) }
    def source(tenancy); end

    sig { params(mapping: Mapping).returns(String) }
    def fingerprint(mapping); end

    sig { params(check: GraphqlCheck, tenancy: T::Boolean).returns(String) }
    def quantifier(check, tenancy); end

    sig { params(check: GraphqlCheck, tenancy: T::Boolean).returns(String) }
    def field_read(check, tenancy); end

    sig { params(check: GraphqlCheck, instance: Receipt::Instance).returns(T.nilable(String)) }
    def path(check, instance); end

    sig { params(type_name: String).returns(String) }
    def signature(type_name); end

    sig { params(edge: Edge).returns(String) }
    def way(edge); end

    sig { returns(T::Hash[String, T::Array[String]]) }
    def notes; end

    private

    sig { void }
    def build; end

    sig { void }
    def settle; end

    sig { returns(T::Array[Edge]) }
    def distinct_roots; end

    sig { void }
    def name_relations; end

    sig { params(name: String, taken: T::Array[String]).returns(String) }
    def unique(name, taken); end

    sig { params(edge: Edge).returns(String) }
    def relation_name(edge); end

    sig { params(parent: T.nilable(String), fields: T::Array[Extractor::GraphqlSchema::Field]).returns(T::Array[Edge]) }
    def walk(parent, fields); end

    sig do
      params(parent: T.nilable(String), steps: T::Array[Step], through: T::Array[String],
             unread: T::Array[String]).returns(T::Array[Edge])
    end
    def descend(parent, steps, through, unread); end

    sig do
      params(type: Extractor::GraphqlSchema::Type, field: Extractor::GraphqlSchema::Field).returns(T::Array[String])
    end
    def checks_on(type, field); end

    sig do
      params(parent: T.nilable(String), steps: T::Array[Step], through: T::Array[String],
             unread: T::Array[String]).returns(Edge)
    end
    def edge(parent, steps, through, unread); end

    sig do
      params(parent: T.nilable(String), field: Extractor::GraphqlSchema::Field, guard: Guard, entry: Guard,
             child: String).returns(T::Array[String])
    end
    def bound_reasons(parent, field, guard, entry, child); end

    sig { params(guard: Guard).returns(T::Boolean) }
    def reads_record?(guard); end

    sig { params(field: Extractor::GraphqlSchema::Field, target: String).returns(Guard) }
    def entry_guard(field, target); end

    sig { params(name: String).returns(GraphqlCheck) }
    def type_check(name); end

    sig { params(type: Extractor::GraphqlSchema::Type).returns(String) }
    def guard_origin(type); end

    sig { params(name: String).returns(T::Array[GraphqlCheck]) }
    def field_checks(name); end

    sig { params(field: Extractor::GraphqlSchema::Field).returns(String) }
    def field_origin(field); end

    sig { params(edge: Edge).returns(String) }
    def describe(edge); end

    sig { returns(T::Array[String]) }
    def opaque_checks; end
  end
end
