# typed: strict

module Hallmark
  class Extractor
    class SourceIndex
      ACTION_POLICY_BASE = T.let(T.unsafe(nil), String)

      class Method
        sig { returns(String) }
        def name; end

        sig { returns(Prism::DefNode) }
        def node; end

        sig { returns(String) }
        def file; end

        # :public, :protected or :private
        sig { returns(Symbol) }
        def visibility; end

        sig { params(visibility: Symbol).returns(Symbol) }
        def visibility=(visibility); end

        # The class or module that defines it
        sig { returns(String) }
        def owner; end

        sig { params(name: String, node: Prism::DefNode, file: String, visibility: Symbol, owner: String).void }
        def initialize(name:, node:, file:, visibility:, owner:); end

        sig { returns(Integer) }
        def line; end

        sig { returns(String) }
        def location; end

        sig { returns(T::Boolean) }
        def arity_zero?; end
      end

      class PreCheck
        sig { returns(String) }
        def name; end

        sig { returns(T.nilable(T::Array[String])) }
        def only; end

        sig { returns(T.nilable(T::Array[String])) }
        def except; end

        sig do
          params(name: String, only: T.nilable(T::Array[String]), except: T.nilable(T::Array[String])).void
        end
        def initialize(name:, only: nil, except: nil); end

        sig { params(rule: String).returns(T::Boolean) }
        def applies?(rule); end
      end

      class Scope
        sig { returns(String) }
        def name; end

        # As written in the source, unresolved
        sig { returns(T.nilable(String)) }
        def superclass; end

        sig { params(superclass: T.nilable(String)).returns(T.nilable(String)) }
        def superclass=(superclass); end

        sig { returns(T::Array[String]) }
        def namespace; end

        sig { returns(T::Hash[String, Method]) }
        def defs; end

        sig { returns(T::Array[String]) }
        def includes; end

        sig { returns(T::Hash[String, String]) }
        def aliases; end

        sig { returns(T.nilable(String)) }
        def default_rule; end

        sig { params(default_rule: T.nilable(String)).returns(T.nilable(String)) }
        def default_rule=(default_rule); end

        sig { returns(T::Array[PreCheck]) }
        def pre_checks; end

        sig { returns(T::Array[PreCheck]) }
        def skipped_pre_checks; end

        # Class attribute name => the literal (true, false or nil) the body sets
        sig { returns(T::Hash[String, Prism::Node]) }
        def attributes; end

        sig { returns(T::Hash[String, Prism::DefNode]) }
        def singletons; end

        sig do
          params(name: String, superclass: T.nilable(String), namespace: T::Array[String],
                 defs: T::Hash[String, Method], includes: T::Array[String], aliases: T::Hash[String, String],
                 default_rule: T.nilable(String), pre_checks: T::Array[PreCheck],
                 skipped_pre_checks: T::Array[PreCheck], attributes: T::Hash[String, Prism::Node],
                 singletons: T::Hash[String, Prism::DefNode]).void
        end
        def initialize(name:, superclass:, namespace:, defs:, includes:, aliases:, default_rule:, pre_checks:,
                       skipped_pre_checks:, attributes:, singletons:); end
      end

      sig { returns(String) }
      attr_reader :root

      sig { returns(T::Hash[String, Scope]) }
      attr_reader :scopes

      sig { params(root: String, dirs: T::Array[String]).void }
      def initialize(root, dirs)
        @root = T.let(T.unsafe(nil), String)
        @scopes = T.let(T.unsafe(nil), T::Hash[String, Scope])
      end

      sig { params(name: String, seen: T::Array[String]).returns(T::Array[String]) }
      def ancestors(name, seen = []); end

      sig { params(name: String).returns(T::Boolean) }
      def action_policy?(name); end

      sig { params(class_name: String, name: String, after: T.nilable(String)).returns(T.nilable(Method)) }
      def find_method(class_name, name, after: nil); end

      sig { params(class_name: String, name: String).returns(T.nilable(Prism::Node)) }
      def attribute(class_name, name); end

      sig { params(class_name: String).returns(T::Array[String]) }
      def rules(class_name); end

      sig { params(class_name: String).returns(T.nilable(String)) }
      def default_rule(class_name); end

      sig { params(class_name: String, rule: String).returns(T::Array[PreCheck]) }
      def pre_checks(class_name, rule); end

      sig { returns(T::Array[String]) }
      def policies; end

      private

      sig { params(path: String).void }
      def index_file(path); end

      sig { params(node: T.nilable(Prism::Node), namespace: T::Array[String], file: String).void }
      def walk(node, namespace, file); end

      sig { params(name: String, namespace: T::Array[String]).returns(Scope) }
      def scope_for(name, namespace); end

      sig { params(scope: Scope, node: T.nilable(Prism::Node), file: String, parts: T::Array[String]).void }
      def body(scope, node, file, parts); end

      sig { params(scope: Scope, node: Prism::DefNode, file: String, visibility: Symbol).void }
      def define(scope, node, file, visibility); end

      VISIBILITIES = T.let(T.unsafe(nil), T::Array[Symbol])

      sig { params(scope: Scope, call: Prism::CallNode, file: String, visibility: Symbol).returns(Symbol) }
      def declaration(scope, call, file, visibility); end

      sig { params(scope: Scope, call: Prism::CallNode, args: T::Array[Prism::Node]).void }
      def macro(scope, call, args); end

      sig { params(scope: Scope, node: T.nilable(Prism::Node)).void }
      def singleton_body(scope, node); end

      sig { params(scope: Scope, args: T::Array[Prism::Node]).void }
      def class_attribute(scope, args); end

      sig { params(scope: Scope, call: Prism::CallNode).void }
      def attribute_write(scope, call); end

      sig { params(scope: Scope, call: Prism::CallNode).void }
      def class_method_call(scope, call); end

      sig { params(scope: Scope, name: String).returns(T.nilable(Prism::DefNode)) }
      def ancestor_singleton(scope, name); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def literal?(node); end

      sig { params(scope: Scope, arg: Prism::Node, file: String, visibility: Symbol).void }
      def visibility_of(scope, arg, file, visibility); end

      sig { params(scope: Scope, args: T::Array[Prism::Node]).void }
      def alias_rule(scope, args); end

      sig { params(scope: Scope, new_name: T.nilable(String), old_name: T.nilable(String)).void }
      def alias_names(scope, new_name, old_name); end

      sig { params(args: T::Array[Prism::Node]).returns(T::Array[PreCheck]) }
      def pre_checks_of(args); end

      sig do
        params(value: T.nilable(T.any(String, T::Array[String]))).returns(T.nilable(T::Array[String]))
      end
      def names(value); end

      sig { params(args: T::Array[Prism::Node], key: Symbol).returns(T.nilable(T.any(String, T::Array[String]))) }
      def keyword(args, key); end

      sig { params(args: T::Array[Prism::Node], key: Symbol).returns(T.nilable(Prism::Node)) }
      def keyword_node(args, key); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def symbol(node); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def constant?(node); end

      sig { params(node: Prism::Node, absolute: T::Boolean).returns(String) }
      def constant_name(node, absolute: false); end

      sig { params(name: String, namespace: T::Array[String]).returns(T.nilable(String)) }
      def resolve(name, namespace); end

      sig { params(name: String).returns(T.nilable(String)) }
      def external_superclass(name); end
    end
  end
end
