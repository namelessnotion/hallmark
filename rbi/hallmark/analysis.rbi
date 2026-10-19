# typed: strict

module Hallmark
  class Analysis
    sig { returns(String) }
    attr_reader :name

    sig { returns(Mapping) }
    attr_reader :mapping

    sig { returns(T::Array[Exposure]) }
    attr_reader :exposures

    # Set once `stamps` has inferred exposures
    sig { returns(T.nilable(Inference)) }
    attr_reader :inference

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
      @exposures = T.let(T.unsafe(nil), T::Array[Exposure])
      @inference = T.let(T.unsafe(nil), T.nilable(Inference))
    end

    # `guard` is checked at run time, since callers without Sorbet can pass anything.
    sig do
      params(
        action: T.any(String, Symbol),
        op: Symbol,
        resource: T.any(String, Symbol, T::Module[T.anything]),
        guard: Object,
        basis: T.nilable(String),
        locations: T.nilable(T::Array[String])
      ).returns(Exposure)
    end
    def add_exposure(action:, op:, resource:, guard:, basis: nil, locations: nil); end

    sig { params(source: T.any(StampSet, String, Pathname)).returns(Inference) }
    def add_stamps(source); end

    sig { returns(T.self_type) }
    def validate!; end

    # The solver is not started when there is nothing to check.
    sig { params(solver: T.nilable(Solver::Backend)).returns(Report) }
    def run(solver: nil); end

    private

    sig { params(exposure: Exposure).void }
    def validate_tenants!(exposure); end

    sig { params(guard: Guard, resource: Mapping::Resource, what: String).void }
    def validate_flags!(guard, resource, what); end

    sig { params(exposure: Exposure, resource: Mapping::Resource).void }
    def validate_outside_tenants!(exposure, resource); end

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
        params(action: T.any(String, Symbol), resource: T.any(String, Symbol, T::Module[T.anything]), guard: Guard).returns(Exposure)
      end
      def reads(action, resource, guard:); end

      sig do
        params(action: T.any(String, Symbol), resource: T.any(String, Symbol, T::Module[T.anything]), guard: Guard).returns(Exposure)
      end
      def writes(action, resource, guard:); end

      sig { params(source: T.any(StampSet, String, Pathname)).returns(Inference) }
      def stamps(source = Hallmark.configuration.stamps); end
    end
  end
end
