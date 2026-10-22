# typed: strict

module Hallmark
  class Extractor
    class SourceIndex
      ACTION_POLICY_BASE = T.let(T.unsafe(nil), String)
      CALLBACKS = T.let(T.unsafe(nil), T::Array[Symbol])

      class Callback
        # :before, :skip_before, :after or :skip_after
        sig { returns(Symbol) }
        def kind; end

        sig { returns(T::Array[String]) }
        def names; end

        sig { returns(T.nilable(Prism::Node)) }
        def only; end

        sig { returns(T.nilable(Prism::Node)) }
        def except; end

        sig { returns(T::Boolean) }
        def prepend; end

        sig { returns(String) }
        def owner; end

        sig do
          params(kind: Symbol, names: T::Array[String], only: T.nilable(Prism::Node), except: T.nilable(Prism::Node),
                 prepend: T::Boolean, owner: String).void
        end
        def initialize(kind:, names:, only:, except:, prepend:, owner:); end
      end

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

      class Call
        sig { returns(Prism::CallNode) }
        def node; end

        sig { returns(String) }
        def file; end

        sig { returns(String) }
        def owner; end

        sig { params(node: Prism::CallNode, file: String, owner: String).void }
        def initialize(node:, file:, owner:); end

        sig { returns(Symbol) }
        def name; end

        sig { returns(T::Array[Prism::Node]) }
        def arguments; end

        sig { returns(String) }
        def location; end
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

        sig { returns(T::Array[Callback]) }
        def callbacks; end

        # Constant name => the value the class body assigns
        sig { returns(T::Hash[String, Prism::Node]) }
        def constants; end

        sig { returns(T::Hash[String, Condition]) }
        def conditions; end

        sig { returns(T::Array[DpRule]) }
        def dp_rules; end

        sig { returns(T::Array[Delegate]) }
        def delegates; end

        sig { returns(T::Array[String]) }
        def overrides; end

        # EE modules prepend_mod_with adds ("EE::ProjectPolicy"), and modules
        # `prepend` names as written
        sig { returns(T::Array[String]) }
        def prepends; end

        # True for a module, false for a class, nil when only referenced
        sig { returns(T.nilable(T::Boolean)) }
        def module; end

        sig { params(value: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
        def module=(value); end

        # Receiverless calls in the class body, as written
        sig { returns(T::Array[Call]) }
        def calls; end

        # Where the class or module is first opened ("app/graphql/types/x.rb:3")
        sig { returns(T.nilable(String)) }
        def location; end

        sig { params(value: T.nilable(String)).returns(T.nilable(String)) }
        def location=(value); end

        sig do
          params(name: String, superclass: T.nilable(String), namespace: T::Array[String],
                 defs: T::Hash[String, Method], includes: T::Array[String], aliases: T::Hash[String, String],
                 default_rule: T.nilable(String), pre_checks: T::Array[PreCheck],
                 skipped_pre_checks: T::Array[PreCheck], attributes: T::Hash[String, Prism::Node],
                 singletons: T::Hash[String, Prism::DefNode], callbacks: T::Array[Callback],
                 constants: T::Hash[String, Prism::Node], conditions: T::Hash[String, Condition],
                 dp_rules: T::Array[DpRule], delegates: T::Array[Delegate], overrides: T::Array[String],
                 prepends: T::Array[String], module: T.nilable(T::Boolean), calls: T::Array[Call],
                 location: T.nilable(String)).void
        end
        def initialize(name:, superclass:, namespace:, defs:, includes:, aliases:, default_rule:, pre_checks:,
                       skipped_pre_checks:, attributes:, singletons:, callbacks:, constants:, conditions:, dp_rules:,
                       delegates:, overrides:, prepends:, module: nil, calls: [], location: nil); end
      end

      sig { returns(String) }
      attr_reader :root

      sig { returns(T::Hash[String, Scope]) }
      attr_reader :scopes

      sig { params(root: String, dirs: T::Array[String]).void }
      def initialize(root, dirs)
        @pending_scope = T.let(T.unsafe(nil), T.nilable(String))
        @root = T.let(T.unsafe(nil), String)
        @scopes = T.let(T.unsafe(nil), T::Hash[String, Scope])
        @ancestors = T.let(T.unsafe(nil), T::Hash[String, T::Array[String]])
      end

      sig { params(name: String).returns(T::Array[String]) }
      def ancestors(name); end

      sig { params(name: String, seen: T::Array[String]).returns(T::Array[String]) }
      def collect_ancestors(name, seen); end

      sig { params(scope: Scope).returns(T::Array[String]) }
      def prepended_modules(scope); end

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

      sig { params(name: String, namespace: T::Array[String]).returns(T.nilable(String)) }
      def resolve_constant(name, namespace); end

      sig { params(class_name: String).returns(T::Array[Callback]) }
      def callbacks(class_name); end

      sig { params(class_name: String).returns(T::Array[Call]) }
      def calls(class_name); end

      sig { params(class_name: String, base: String).returns(T::Boolean) }
      def inherits?(class_name, base); end

      sig { params(class_name: String, callback: Callback, action: String).returns(T::Boolean) }
      def applies?(class_name, callback, action); end

      sig { params(class_name: String, node: T.nilable(Prism::Node)).returns(T.nilable(T::Array[String])) }
      def names_in(class_name, node); end

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

      sig { params(scope: Scope, node: Prism::DefNode, file: String).returns(Prism::DefNode) }
      def define_singleton(scope, node, file); end

      VISIBILITIES = T.let(T.unsafe(nil), T::Array[Symbol])

      sig do
        params(scope: Scope, call: Prism::CallNode, file: String, visibility: Symbol, parts: T::Array[String])
          .returns(Symbol)
      end
      def declaration(scope, call, file, visibility, parts); end

      sig do
        params(scope: Scope, call: Prism::CallNode, args: T::Array[Prism::Node], file: String,
               parts: T::Array[String]).void
      end
      def macro(scope, call, args, file, parts); end

      sig { params(scope: Scope, call: Prism::CallNode, args: T::Array[Prism::Node]).void }
      def policy_macro(scope, call, args); end

      sig { params(call: Prism::CallNode, namespace: T::Array[String]).void }
      def prepend_mod(call, namespace); end

      sig { params(scope: Scope, node: T.any(Prism::ClassNode, Prism::ModuleNode)).void }
      def mark_kind(scope, node); end

      sig { params(call: Prism::CallNode).returns(T.nilable(Prism::Node)) }
      def block_body(call); end

      sig { params(scope: Scope, name: Symbol, args: T::Array[Prism::Node]).void }
      def callback(scope, name, args); end

      sig { params(class_name: String, name: String).returns(T.nilable(Prism::Node)) }
      def constant(class_name, name); end

      sig { params(scope: Scope, node: T.nilable(Prism::Node), file: String).void }
      def singleton_body(scope, node, file); end

      sig { params(scope: Scope, name: Symbol, args: T::Array[Prism::Node]).void }
      def mixin(scope, name, args); end

      sig { params(scope: Scope, call: Prism::CallNode, file: String).void }
      def record_call(scope, call, file); end

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

      sig { params(scope: Scope).returns(T.nilable(String)) }
      def parent_of(scope); end

      sig { params(scope: Scope, name: String).returns(T.nilable(String)) }
      def inherited_constant(scope, name); end

      sig { params(name: String).returns(T.nilable(String)) }
      def external_superclass(name); end
    end
  end
end
