# typed: strict

module Hallmark
  class Extractor
    class RoutesFile
      FILE = T.let(T.unsafe(nil), String)
      DRAWN = T.let(T.unsafe(nil), String)
      INITIALIZERS = T.let(T.unsafe(nil), String)
      VERBS = T.let(T.unsafe(nil), T::Array[String])
      PLURAL = T.let(T.unsafe(nil), T::Array[String])
      SINGULAR = T.let(T.unsafe(nil), T::Array[String])
      SAME_SCOPE = T.let(T.unsafe(nil), T::Array[String])
      SKIPPED = T.let(T.unsafe(nil), T::Array[String])

      class Scope
        # Controller modules around the route ("admin")
        sig { returns(T::Array[String]) }
        def modules; end

        sig { returns(String) }
        def path; end

        # The controller a bare route name belongs to ("events"), if any
        sig { returns(T.nilable(String)) }
        def controller; end

        # The path a bare route adds inside a resource's block ("/:event_id")
        sig { returns(String) }
        def nested; end

        # The path a member route adds ("/:id")
        sig { returns(String) }
        def member; end

        sig do
          params(modules: T::Array[String], path: String, controller: T.nilable(String), nested: String,
                 member: String).void
        end
        def initialize(modules:, path:, controller:, nested:, member:); end

        sig do
          params(modules: T::Array[String], path: String, controller: T.nilable(String), nested: String,
                 member: String).returns(Scope)
        end
        def under(modules: T.unsafe(nil), path: T.unsafe(nil), controller: T.unsafe(nil), nested: "", member: ""); end
      end

      sig { returns(T::Array[Route]) }
      attr_reader :routes

      sig { params(root: String).void }
      def initialize(root)
        @root = T.let(T.unsafe(nil), String)
        @routes = T.let(T.unsafe(nil), T::Array[Route])
        @concerns = T.let(T.unsafe(nil), T::Hash[String, Prism::Node])
        @drawn = T.let(T.unsafe(nil), T::Array[String])
        @acronyms = T.let(T.unsafe(nil), T::Hash[String, String])
      end

      private

      sig { returns(T::Hash[String, String]) }
      def acronyms; end

      sig { params(node: T.nilable(Prism::Node), found: T::Hash[String, String]).void }
      def collect_acronyms(node, found); end

      sig { params(path: String, scope: Scope).void }
      def read(path, scope); end

      sig { params(node: T.nilable(Prism::Node), scope: Scope).void }
      def walk(node, scope); end

      sig { params(node: Prism::CallNode, scope: Scope).void }
      def call(node, scope); end

      sig { params(name: String, node: Prism::CallNode, args: T::Array[Prism::Node], scope: Scope).void }
      def block_call(name, node, args, scope); end

      sig { params(args: T::Array[Prism::Node], verbs: T::Array[String], scope: Scope).void }
      def route(args, verbs, scope); end

      sig { params(args: T::Array[Prism::Node]).returns(T.nilable([T.nilable(String), T.nilable(String)])) }
      def written(args); end

      sig do
        params(target: T.nilable(String), path: T.nilable(String), args: T::Array[Prism::Node],
               scope: Scope).returns(T.nilable(T::Array[T.nilable(String)]))
      end
      def target_of(target, path, args, scope); end

      sig do
        params(path: T.nilable(String), controller: T.nilable(String)).returns(T.nilable(T::Array[T.nilable(String)]))
      end
      def bare_target(path, controller); end

      sig { params(args: T::Array[Prism::Node], scope: Scope).void }
      def root(args, scope); end

      sig { params(node: Prism::CallNode, args: T::Array[Prism::Node], scope: Scope, plural: T::Boolean).void }
      def resources(node, args, scope, plural:); end

      sig do
        params(node: Prism::CallNode, name: String, args: T::Array[Prism::Node], scope: Scope, plural: T::Boolean).void
      end
      def resource(node, name, args, scope, plural:); end

      sig { params(args: T::Array[Prism::Node], plural: T::Boolean).returns(T::Array[String]) }
      def default_actions(args, plural); end

      sig { params(scope: Scope, action: String, plural: T::Boolean).void }
      def default_route(scope, action, plural:); end

      sig { params(node: Prism::CallNode, args: T::Array[Prism::Node], scope: Scope).void }
      def namespace(node, args, scope); end

      sig { params(node: Prism::CallNode, args: T::Array[Prism::Node], scope: Scope).void }
      def scoped(node, args, scope); end

      sig { params(node: Prism::CallNode, args: T::Array[Prism::Node], scope: Scope).void }
      def controller_scope(node, args, scope); end

      sig { params(node: Prism::CallNode, args: T::Array[Prism::Node]).void }
      def concern(node, args); end

      sig { params(args: T::Array[Prism::Node], scope: Scope).void }
      def draw(args, scope); end

      sig { params(scope: Scope, controller: String, action: String, verb: String, path: String).void }
      def add(scope, controller, action, verb, path); end

      sig { params(args: T::Array[Prism::Node]).returns(T::Array[String]) }
      def via(args); end

      sig { params(args: T::Array[Prism::Node]).returns(T.nilable(Prism::AssocNode)) }
      def rocket(args); end

      sig { params(args: T::Array[Prism::Node], key: String).returns(T.nilable(Prism::Node)) }
      def keyword(args, key); end

      sig { params(args: T::Array[Prism::Node]).returns(T::Array[String]) }
      def names(args); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(T::Array[String])) }
      def names_of(node); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def symbol(node); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def string(node); end

      sig { params(name: String).returns(String) }
      def plural_of(name); end

      sig { params(name: String).returns(String) }
      def singular_of(name); end
    end
  end
end
