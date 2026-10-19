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
      @translator = T.let(T.unsafe(nil), MethodTranslator)
      @cache = T.let(T.unsafe(nil), T::Hash[String, T.nilable(Extracted)])
      @controllers = T.let(T.unsafe(nil), T.nilable(Controllers))
    end

    sig { returns(Controllers) }
    def controllers; end

    sig { returns(T::Array[Extracted]) }
    def rules; end

    sig { params(policy: String, rule: String).returns(T.nilable(Extracted)) }
    def fetch(policy, rule); end

    private

    sig { params(policy: String, rule: String).returns(T.nilable(Extracted)) }
    def extract(policy, rule); end

    sig { params(policy: String, rule: String).returns(T.nilable(String)) }
    def resource_for(policy, rule); end
  end
end
