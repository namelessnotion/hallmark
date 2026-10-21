# typed: strict

module Hallmark
  class RuleCheck
    class Result
      sig { returns(String) }
      def policy; end

      sig { returns(String) }
      def rule; end

      # Nil only when the rule was not observed
      sig { returns(T.nilable(Exposure)) }
      def exposure; end

      sig { params(exposure: T.nilable(Exposure)).returns(T.nilable(Exposure)) }
      def exposure=(exposure); end

      # :counterexample, :none, :unknown or :not_observed; nil until checked
      sig { returns(T.nilable(Symbol)) }
      def verdict; end

      sig { params(verdict: Symbol).returns(Symbol) }
      def verdict=(verdict); end

      sig { returns(T.nilable(Finding)) }
      def finding; end

      sig { params(finding: Finding).returns(Finding) }
      def finding=(finding); end

      sig { returns(T.nilable(String)) }
      def reason; end

      sig { params(reason: String).returns(String) }
      def reason=(reason); end

      # The rule's drift on this kind of record; nil or empty for none
      sig { returns(T.nilable(T::Array[Drift])) }
      def drift; end

      sig { returns(T::Array[Drift]) }
      def drifts; end

      sig do
        params(policy: String, rule: String, exposure: T.nilable(Exposure), verdict: T.nilable(Symbol),
               finding: T.nilable(Finding), reason: T.nilable(String), drift: T.nilable(T::Array[Drift])).void
      end
      def initialize(policy:, rule:, exposure: nil, verdict: nil, finding: nil, reason: nil, drift: nil); end

      sig { returns(String) }
      def key; end

      sig { returns(T::Boolean) }
      def counterexample?; end

      sig { returns(T::Boolean) }
      def none?; end

      sig { returns(T::Boolean) }
      def drift?; end

      sig { returns(T::Array[String]) }
      def lines; end

      private

      sig { returns(T::Array[String]) }
      def verdict_lines; end
    end

    sig { returns(Mapping) }
    attr_reader :mapping

    sig { returns(StampSet) }
    attr_reader :stamps

    sig { params(mapping: Mapping, stamps: StampSet, extractor: T.nilable(Extractor)).void }
    def initialize(mapping, stamps = StampSet.new, extractor: nil)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @stamps = T.let(T.unsafe(nil), StampSet)
      @units = T.let(T.unsafe(nil), T::Array[Inference::Unit])
      @drift = T.let(T.unsafe(nil), T::Array[Drift])
      @ops = T.let(T.unsafe(nil), Ops)
    end

    sig { params(policy: T.any(String, T::Module[T.anything])).returns(T::Array[String]) }
    def rules(policy); end

    sig do
      params(
        policy: T.any(String, T::Module[T.anything]),
        names: T.nilable(T::Array[T.any(String, Symbol)]),
        solver: Solver::Backend
      ).returns(T::Array[Result])
    end
    def check(policy, names = nil, solver: Hallmark.solver); end

    private

    sig { params(name: String, checked: T::Array[Result]).returns(Analysis) }
    def analysis(name, checked); end

    sig { params(policy: String, rule: String).returns(T::Array[Result]) }
    def pending(policy, rule); end

    sig { params(unit: Inference::Unit).returns(Result) }
    def from_unit(unit); end

    sig { params(rule: Mapping::Rule, guard: Guard).returns(Result) }
    def from_rule(rule, guard); end

    sig { params(unit: Inference::Unit).returns(String) }
    def unguarded(unit); end

    sig { params(rule: Mapping::Rule).returns(String) }
    def convention(rule); end

    sig { params(key: String).returns(String) }
    def unstamped(key); end

    sig { params(report: Report, checked: T::Array[Result]).void }
    def record(report, checked); end
  end
end
