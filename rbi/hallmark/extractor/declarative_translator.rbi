# typed: strict

module Hallmark
  class Extractor
    class DeclarativeTranslator
      class Lint
        # "D3" or "D4"
        sig { returns(String) }
        def kind; end

        sig { returns(String) }
        def location; end

        sig { returns(String) }
        def message; end

        # The GraphQL type a G5 lint concerns; nil otherwise
        sig { returns(T.nilable(String)) }
        def subject; end

        sig { params(kind: String, location: String, message: String, subject: T.nilable(String)).void }
        def initialize(kind:, location:, message:, subject: nil); end

        sig { returns(String) }
        def to_s; end
      end

      Steps = T.type_alias { [T::Array[Guard], T::Array[Guard]] }

      sig { returns(T::Array[Lint]) }
      attr_reader :lints

      sig { params(index: SourceIndex, terms: Terms, methods: MethodTranslator).void }
      def initialize(index, terms, methods)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @terms = T.let(T.unsafe(nil), Terms)
        @methods = T.let(T.unsafe(nil), MethodTranslator)
        @resource = T.let(T.unsafe(nil), T.nilable(String))
        @memo = T.let(T.unsafe(nil), T::Hash[String, Guard])
        @lints = T.let(T.unsafe(nil), T::Array[Lint])
      end

      sig { params(class_name: String, ability: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def ability(class_name, ability, resource); end

      private

      class Place
        sig { returns(String) }
        def klass; end

        sig { returns(String) }
        def subject; end

        sig { returns(T::Array[String]) }
        def stack; end

        sig { params(klass: String, subject: String, stack: T::Array[String]).void }
        def initialize(klass:, subject:, stack:); end
      end

      sig { params(klass: String, ability: String, subject: String, stack: T::Array[String]).returns(Guard) }
      def evaluate(klass, ability, subject, stack); end

      sig { params(place: Place, ability: String).returns(Steps) }
      def steps(place, ability); end

      sig { params(place: Place, ability: String, enables: T::Array[Guard], prevents: T::Array[Guard]).void }
      def delegated(place, ability, enables, prevents); end

      sig { params(delegate: SourceIndex::Delegate).returns([T.nilable(String), T.nilable(String)]) }
      def delegate_target(delegate); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def subject_reader(node); end

      sig { params(node: T.nilable(Prism::Node), klass: String).returns(T.nilable(String)) }
      def helper_reader(node, klass); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Boolean) }
      def subject?(node); end

      sig { params(node: T.nilable(Prism::Node), rule: SourceIndex::DpRule, place: Place).returns(Guard) }
      def expression(node, rule, place); end

      sig { params(node: T.any(Prism::AndNode, Prism::OrNode), rule: SourceIndex::DpRule, place: Place).returns(Guard) }
      def boolean(node, rule, place); end

      sig { params(node: Prism::CallNode, rule: SourceIndex::DpRule, place: Place).returns(Guard) }
      def call(node, rule, place); end

      sig { params(node: Prism::CallNode).returns(T.nilable(String)) }
      def can_query(node); end

      sig do
        params(node: Prism::CallNode, receiver: Prism::Node, rule: SourceIndex::DpRule, place: Place).returns(Guard)
      end
      def operator(node, receiver, rule, place); end

      sig { params(name: String, klass: String, subject: String).returns(Guard) }
      def condition(name, klass, subject); end

      sig { params(name: String, klass: String, subject: String).returns(Guard) }
      def condition_body(name, klass, subject); end

      sig { params(klass: String, subject: String).returns(T::Hash[String, String]) }
      def subject_aliases(klass, subject); end

      sig { params(body: T.nilable(Prism::Node), subject: String).returns(T.nilable(String)) }
      def subject_alias(body, subject); end

      sig { params(found: SourceIndex::Condition, aliases: T::Hash[String, String]).void }
      def check_scope(found, aliases); end

      sig { params(scope: T.nilable(String)).returns(T::Array[String]) }
      def excluded_by(scope); end

      sig { params(body: T.nilable(Prism::Node), aliases: T::Hash[String, String]).returns(T::Array[String]) }
      def reads(body, aliases); end

      sig { params(node: Prism::Node, aliases: T::Hash[String, String]).returns(T::Boolean) }
      def subject_read?(node, aliases); end

      sig { params(name: String).returns(Guard) }
      def builtin(name); end

      sig { params(kind: String, location: String, message: String).void }
      def lint(kind, location, message); end

      sig { params(guards: T::Array[Guard]).returns(Guard) }
      def any(guards); end

      sig { params(node: Prism::Node, rule: SourceIndex::DpRule).returns(Guard) }
      def opaque(node, rule); end
    end
  end
end
