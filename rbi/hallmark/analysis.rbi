# typed: strict

module Hallmark
  class Analysis
    sig { returns(String) }
    attr_reader :name

    sig { returns(Mapping) }
    attr_reader :mapping

    sig { returns(T::Array[AnyExposure]) }
    attr_reader :exposures

    # Set once `stamps` has inferred exposures
    sig { returns(T.nilable(Inference)) }
    attr_reader :inference

    # The GraphQL model its checks come from, if any
    sig { returns(T.nilable(GraphqlModel)) }
    attr_reader :graphql

    sig do
      params(
        name: T.any(String, Symbol),
        mapping: T.nilable(Mapping),
        block: T.nilable(T.proc.bind(Builder).void)
      ).returns(Analysis)
    end
    def self.build(name, mapping: nil, &block); end

    sig { params(name: T.any(String, Symbol), mapping: T.nilable(Mapping)).void }
    def initialize(name, mapping: nil)
      @name = T.let(T.unsafe(nil), String)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @exposures = T.let(T.unsafe(nil), T::Array[AnyExposure])
      @inference = T.let(T.unsafe(nil), T.nilable(Inference))
      @graphql = T.let(T.unsafe(nil), T.nilable(GraphqlModel))
    end

    # `guard` is checked at run time, since callers without Sorbet can pass anything.
    sig do
      params(
        action: T.any(String, Symbol),
        op: Symbol,
        resource: T.any(String, Symbol, T::Module[T.anything]),
        guard: Object,
        basis: T.nilable(String),
        locations: T.nilable(T::Array[String]),
        rules: T.nilable(T::Array[String]),
        field: T.nilable(T.any(String, Symbol)),
        kind: T.nilable(Symbol),
        shown_by: T.nilable(String)
      ).returns(Exposure)
    end
    def add_exposure(action:, op:, resource:, guard:, basis: nil, locations: nil, rules: nil, field: nil, kind: nil,
                     shown_by: nil); end

    sig { params(check: GraphqlCheck).returns(GraphqlCheck) }
    def add_check(check); end

    sig { params(root: T.nilable(String)).returns(T.nilable(GraphqlModel)) }
    def add_graphql(root = Hallmark.configuration.root); end

    sig { params(source: T.any(StampSet, String, Pathname), root: T.nilable(String)).returns(Inference) }
    def add_stamps(source, root: Hallmark.configuration.root); end

    # Inference from code alone: routes from config/routes.rb, no stamps
    sig { params(root: T.nilable(String)).returns(Inference) }
    def add_code(root = Hallmark.configuration.root); end

    sig { params(exposure: AnyExposure).returns(AnyExposure) }
    def add(exposure); end

    sig { returns(T.self_type) }
    def validate!; end

    # Field reads with no field policy, checked as readable as their record
    sig { returns(T::Array[AnyExposure]) }
    def fields_without_policy; end

    # The solver is not started when there is nothing to check.
    sig { params(solver: T.nilable(Solver::Backend)).returns(Report) }
    def run(solver: nil); end

    private

    sig { params(set: StampSet, extractor: T.nilable(Extractor)).returns(Inference) }
    def infer(set, extractor); end

    sig do
      params(action: T.any(String, Symbol), op: Symbol, field: T.nilable(T.any(String, Symbol)),
             kind: T.nilable(Symbol)).void
    end
    def validate_field!(action, op, field, kind); end

    sig { params(exposure: AnyExposure).void }
    def validate_tenants!(exposure); end

    sig { params(guard: Guard, what: String).void }
    def validate_guard_tenants!(guard, what); end

    sig { params(policy: Mapping::FieldPolicy).void }
    def validate_field_policy!(policy); end

    sig { void }
    def validate_graphql!; end

    sig { params(guard: Guard, resource: Mapping::Resource, what: String).void }
    def validate_flags!(guard, resource, what); end

    sig { params(exposure: AnyExposure, resource: Mapping::Resource).void }
    def validate_outside_tenants!(exposure, resource); end

    sig { params(exposure: AnyExposure, resource: Mapping::Resource).void }
    def validate_public_action!(exposure, resource); end

    public

    class Builder
      include Guard::DSL

      sig { params(analysis: Analysis).void }
      def initialize(analysis)
        @analysis = T.let(T.unsafe(nil), Analysis)
      end

      sig { params(blk: T.proc.bind(Mapping).void).void }
      def map(&blk); end

      sig do
        params(action: T.any(String, Symbol), resource: T.any(String, Symbol, T::Module[T.anything]), guard: Guard,
               field: T.nilable(T.any(String, Symbol))).returns(Exposure)
      end
      def reads(action, resource, guard:, field: nil); end

      # Raises when `field:` is given: fields exist only on reads
      sig do
        params(action: T.any(String, Symbol), resource: T.any(String, Symbol, T::Module[T.anything]), guard: Guard,
               field: T.nilable(T.any(String, Symbol))).returns(Exposure)
      end
      def writes(action, resource, guard:, field: nil); end

      sig do
        params(action: T.any(String, Symbol), resource: T.any(String, Symbol, T::Module[T.anything]), guard: Guard)
          .returns(Exposure)
      end
      def lists(action, resource, guard:); end

      sig { params(source: T.any(StampSet, String, Pathname), root: T.nilable(String)).returns(Inference) }
      def stamps(source = Hallmark.configuration.stamps, root: Hallmark.configuration.root); end

      sig { params(root: T.nilable(String)).returns(Inference) }
      def from_code(root = Hallmark.configuration.root); end

      sig { params(root: T.nilable(String)).returns(GraphqlModel) }
      def graphql_schema(root = Hallmark.configuration.root); end
    end
  end
end
