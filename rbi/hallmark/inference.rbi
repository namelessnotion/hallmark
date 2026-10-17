# typed: strict

module Hallmark
  class Inference
    include Guard::DSL

    class Unit
      sig { returns(String) }
      def policy; end

      sig { returns(String) }
      def rule; end

      sig { returns(String) }
      def resource; end

      sig { returns(Symbol) }
      def op; end

      sig { returns(T::Array[Stamp]) }
      def stamps; end

      # Nil when the rule never allowed and the mapping writes no guard
      sig { returns(T.nilable(Guard)) }
      def guard; end

      sig { params(guard: T.nilable(Guard)).returns(T.nilable(Guard)) }
      def guard=(guard); end

      sig { returns(T.nilable(String)) }
      def basis; end

      sig { params(basis: T.nilable(String)).returns(T.nilable(String)) }
      def basis=(basis); end

      sig do
        params(policy: String, rule: String, resource: String, op: Symbol, stamps: T::Array[Stamp],
               guard: T.nilable(Guard), basis: T.nilable(String)).void
      end
      def initialize(policy:, rule:, resource:, op:, stamps:, guard: nil, basis: nil); end

      sig { returns(String) }
      def key; end

      sig { returns(T::Array[Stamp]) }
      def allows; end

      sig { returns(T::Array[Stamp]) }
      def denies; end

      sig { returns(T::Array[String]) }
      def entry_points; end
    end

    # One per rule and resource with stamps, in sorted order; the RSpec
    # matchers check each one's guard on its own
    sig { returns(T::Array[Unit]) }
    attr_reader :units

    sig { returns(T::Array[Exposure]) }
    attr_reader :exposures

    sig { returns(Coverage) }
    attr_reader :coverage

    # Entry points that fail threat 10, sorted
    sig { returns(T::Array[String]) }
    attr_reader :unchecked

    sig { params(mapping: Mapping, stamp_set: StampSet).void }
    def initialize(mapping, stamp_set)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @stamps = T.let(T.unsafe(nil), T::Array[Stamp])
      @coverage = T.let(T.unsafe(nil), Coverage)
      @units = T.let(T.unsafe(nil), T::Array[Unit])
      @exposures = T.let(T.unsafe(nil), T::Array[Exposure])
      @unchecked = T.let(T.unsafe(nil), T::Array[String])
    end

    private

    sig { params(events: T::Array[Unchecked]).returns(T::Array[String]) }
    def classify_unchecked(events); end

    sig { params(event: Unchecked).returns(T::Boolean) }
    def redirect_before_check?(event); end

    sig { returns(T::Array[Unit]) }
    def build_units; end

    sig { params(policy: String, rule: String, resource: String, stamps: T::Array[Stamp]).returns(T.nilable(Unit)) }
    def unit_for(policy, rule, resource, stamps); end

    sig { params(unit: Unit).void }
    def assign_guard(unit); end

    sig { params(allows: T::Array[Stamp], resource: Mapping::Resource).returns(Guard) }
    def inferred_guard(allows, resource); end

    sig { params(guards: T::Array[Guard]).returns(Guard) }
    def conjunction(guards); end

    sig { params(sets: T::Array[T::Array[Guard]]).returns(T::Array[T::Array[Guard]]) }
    def minimal(sets); end

    sig { params(stamp: Stamp, resource: Mapping::Resource).returns(T::Array[Guard]) }
    def literals(stamp, resource); end

    sig { params(stamp: Stamp, resource: Mapping::Resource).returns(T::Array[Guard]) }
    def record_literals(stamp, resource); end

    sig { params(stamp: Stamp, resource: Mapping::Resource, out: T::Array[Guard]).void }
    def tenant_literals(stamp, resource, out); end

    sig { returns(T::Array[Exposure]) }
    def build_exposures; end

    sig { params(entry_point: String, units: T::Array[Unit]).returns(T::Array[Exposure]) }
    def exposures_of(entry_point, units); end

    sig { params(entry_point: String, op: Symbol, resource: String, units: T::Array[Unit]).returns(T.nilable(Exposure)) }
    def exposure_for(entry_point, op, resource, units); end
  end
end
