# typed: strict

module Hallmark
  class Extractor
    class Terms
      include Guard::DSL

      RECORD = T.let(T.unsafe(nil), String)

      sig { params(mapping: Mapping).void }
      def initialize(mapping)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @global = T.let(T.unsafe(nil), T::Hash[String, Guard])
        @by_resource = T.let(T.unsafe(nil), T::Hash[String, T::Hash[String, Guard]])
      end

      sig { params(source: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def lookup(source, resource); end

      sig { params(left: String, right: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def compare(left, right, resource); end

      sig { params(source: T.any(String, Symbol)).returns(String) }
      def self.normalize(source); end

      private

      sig { void }
      def seed; end

      sig { params(resource: Mapping::Resource, user: String).void }
      def seed_resource(resource, user); end

      sig { params(terms: T::Hash[String, Guard], resource: Mapping::Resource).void }
      def seed_tenant(terms, resource); end
    end

    # A local's name => [the node assigned, the locals in force there]
    Locals = T.type_alias { T::Hash[String, [Prism::Node, T.untyped]] }

    class Canonical
      OPERATORS = T.let(T.unsafe(nil), T::Array[Symbol])

      sig { params(locals: Locals, aliases: T::Hash[String, String]).void }
      def initialize(locals, aliases = {})
        @locals = T.let(T.unsafe(nil), Locals)
        @aliases = T.let(T.unsafe(nil), T::Hash[String, String])
      end

      sig { params(node: Prism::Node).returns(String) }
      def render(node); end

      private

      sig { params(node: Prism::CallNode).returns(String) }
      def call(node); end

      sig { params(node: Prism::CallNode).returns(T.nilable(String)) }
      def reader(node); end

      sig { params(node: Prism::CallNode).returns(T::Array[String]) }
      def arguments(node); end

      sig { params(node: Prism::LocalVariableReadNode).returns(String) }
      def local(node); end

      sig { params(node: Prism::ParenthesesNode).returns(String) }
      def parentheses(node); end
    end
  end
end
