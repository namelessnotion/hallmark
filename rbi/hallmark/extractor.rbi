# typed: strict

module Hallmark
  class Extractor
    DIRS = T.let(T.unsafe(nil), T::Array[String])

    class Extracted
      sig { returns(String) }
      def policy; end

      sig { returns(String) }
      def rule; end

      # Nil when no mapped resource matches the policy
      sig { returns(T.nilable(String)) }
      def resource; end

      # The full guard, opaque leaves included
      sig { returns(Guard) }
      def guard; end

      # "app/policies/link_policy.rb:31"
      sig { returns(String) }
      def location; end

      sig do
        params(policy: String, rule: String, resource: T.nilable(String), guard: Guard, location: String).void
      end
      def initialize(policy:, rule:, resource:, guard:, location:); end

      sig { returns(String) }
      def key; end

      sig { returns(Guard) }
      def lower; end

      sig { returns(Guard) }
      def upper; end

      sig { returns(T::Boolean) }
      def exact?; end

      sig { returns(T::Array[Guard]) }
      def opaque_leaves; end
    end

    sig { params(mapping: Mapping, root: T.nilable(String)).returns(T.nilable(Extractor)) }
    def self.load(mapping, root = Hallmark.configuration.root); end

    sig { returns(String) }
    attr_reader :root

    sig { params(mapping: Mapping, root: String).void }
    def initialize(mapping, root)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @root = T.let(T.unsafe(nil), String)
      @index = T.let(T.unsafe(nil), SourceIndex)
      @terms = T.let(T.unsafe(nil), Terms)
      @translator = T.let(T.unsafe(nil), MethodTranslator)
      @declarative = T.let(T.unsafe(nil), DeclarativeTranslator)
      @graphql = T.let(T.unsafe(nil), T.nilable(GraphqlSchema))
      @graphql_read = T.let(T.unsafe(nil), T::Boolean)
      @cache = T.let(T.unsafe(nil), T::Hash[String, T.nilable(Extracted)])
      @controllers = T.let(T.unsafe(nil), T.nilable(Controllers))
      @grape = T.let(T.unsafe(nil), T.nilable(GrapeEndpoints))
      @grape_read = T.let(T.unsafe(nil), T::Boolean)
      @routes = T.let(T.unsafe(nil), T.nilable(T::Array[Route]))
    end

    sig { returns(T::Array[Route]) }
    def routes; end

    sig { returns(T.nilable(GrapeEndpoints)) }
    def grape; end

    sig { returns(Controllers) }
    def controllers; end

    sig { returns(T.nilable(GraphqlSchema)) }
    def graphql; end

    sig { params(resource: String, ability: String).returns(T.nilable(Guard)) }
    def ability_guard(resource, ability); end

    sig { params(resource: String, rule: String, policy: T.nilable(String)).returns(T.nilable(Guard)) }
    def rule_guard(resource, rule, policy = nil); end

    sig { returns(T::Array[Extracted]) }
    def rules; end

    sig { returns(T::Array[DeclarativeTranslator::Lint]) }
    def lints; end

    sig { params(policy: String, rule: String).returns(T.nilable(Extracted)) }
    def fetch(policy, rule); end

    private

    sig { params(policy: String, rule: String).returns(T.nilable(Extracted)) }
    def extract(policy, rule); end

    sig { params(policy: String, rule: String).returns(T.nilable(String)) }
    def resource_for(policy, rule); end

    sig { params(policy: String, ability: String, resource: T.nilable(String)).returns(T.nilable(Extracted)) }
    def extract_ability(policy, ability, resource); end

    sig { params(policy: String).returns(T::Array[String]) }
    def abilities(policy); end
  end
end
