# typed: strict

# RSpec's own types stay T.untyped here, so apps that bundle Hallmark need no
# RSpec RBIs to type-check.
module Hallmark
  module RSpec
    CONFIG_FILE = T.let(T.unsafe(nil), String)

    @solver = T.let(nil, T.nilable(Solver::Backend))

    class << self
      sig { params(solver: T.nilable(Solver::Backend)).void }
      attr_writer :solver

      sig { returns(Solver::Backend) }
      def solver; end

      sig { void }
      def close; end

      sig { returns(Mapping) }
      def mapping; end

      sig { returns(StampSet) }
      def stamps; end

      sig { params(config: T.untyped).void }
      def install(config); end

      sig { params(config: T.untyped).void }
      def order_last(config); end
    end

    class LastOrdering
      sig { params(previous: T.untyped).void }
      def initialize(previous)
        @previous = T.let(T.unsafe(nil), T.untyped)
      end

      sig { params(items: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
      def order(items); end
    end

    class Matcher
      UNKNOWN_NOTE = T.let(T.unsafe(nil), String)
      NOT_OBSERVED_NOTE = T.let(T.unsafe(nil), String)
      DRIFT_NOTE = T.let(T.unsafe(nil), String)

      sig { returns(T::Array[RuleCheck::Result]) }
      attr_reader :results

      sig do
        params(mapping: T.nilable(Mapping), stamps: T.nilable(T.any(StampSet, String)), root: T.nilable(String),
               solver: T.nilable(Solver::Backend)).void
      end
      def initialize(mapping: nil, stamps: nil, root: nil, solver: nil)
        @mapping = T.let(T.unsafe(nil), T.nilable(Mapping))
        @stamps = T.let(T.unsafe(nil), T.nilable(T.any(StampSet, String)))
        @root = T.let(T.unsafe(nil), T.nilable(String))
        @solver = T.let(T.unsafe(nil), T.nilable(Solver::Backend))
        @policy = T.let(T.unsafe(nil), String)
        @results = T.let(T.unsafe(nil), T::Array[RuleCheck::Result])
      end

      sig { params(actual: T.untyped).returns(T::Boolean) }
      def matches?(actual); end

      sig { params(actual: T.untyped).returns(T::Boolean) }
      def does_not_match?(actual); end

      sig { returns(String) }
      def failure_message; end

      sig { returns(String) }
      def failure_message_when_negated; end

      private

      sig { returns(Integer) }
      def scope; end

      sig { returns(String) }
      def target; end

      sig { returns(String) }
      def expectation; end

      sig { returns(T.nilable(T::Array[String])) }
      def rule_names; end

      sig { returns(T::Boolean) }
      def drift?; end

      sig { params(actual: T.untyped).returns(T::Array[RuleCheck::Result]) }
      def run(actual); end

      sig { params(actual: T.untyped).returns(String) }
      def policy_name(actual); end

      sig { returns(StampSet) }
      def stamp_set; end

      sig { returns(String) }
      def outcome; end

      sig { returns(String) }
      def drift_count; end

      sig { params(verdict: Symbol, number: Integer).returns(String) }
      def label(verdict, number); end

      sig { returns(String) }
      def details; end
    end

    class SatisfyCatalog < Matcher
      sig { returns(String) }
      def description; end

      private

      sig { returns(String) }
      def expectation; end
    end

    class HaveNoCounterexample < Matcher
      sig do
        params(rule: T.any(String, Symbol), mapping: T.nilable(Mapping), stamps: T.nilable(T.any(StampSet, String)),
               root: T.nilable(String), solver: T.nilable(Solver::Backend)).void
      end
      def initialize(rule, mapping: nil, stamps: nil, root: nil, solver: nil)
        @rule = T.let(T.unsafe(nil), String)
      end

      sig { returns(String) }
      def description; end

      private

      sig { returns(String) }
      def target; end

      sig { returns(T::Array[String]) }
      def rule_names; end
    end

    # Included into RSpec example groups, which are objects
    module Matchers
      include Kernel

      sig { returns(SatisfyCatalog) }
      def satisfy_catalog; end

      sig { params(rule: T.any(String, Symbol)).returns(HaveNoCounterexample) }
      def have_no_counterexample(rule); end

      private

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def hallmark_options; end

      sig { params(name: Symbol).returns(T.untyped) }
      def hallmark_let(name); end
    end

    module PolicySubject
      sig { params(group: T.untyped).void }
      def self.included(group); end
    end
  end
end
