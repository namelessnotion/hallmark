# typed: strict

module Hallmark
  class Extractor
    class SourceIndex
      DECLARATIVE_BASE = T.let(T.unsafe(nil), String)

      class Condition
        sig { returns(String) }
        def name; end

        sig { returns(T.nilable(Prism::Node)) }
        def body; end

        # "user", "subject", "global", or nil for the default
        sig { returns(T.nilable(String)) }
        def scope; end

        sig { returns(String) }
        def file; end

        sig { returns(Integer) }
        def line; end

        sig { returns(String) }
        def owner; end

        sig do
          params(name: String, body: T.nilable(Prism::Node), scope: T.nilable(String), file: String, line: Integer,
                 owner: String).void
        end
        def initialize(name:, body:, scope:, file:, line:, owner:); end

        sig { returns(String) }
        def location; end
      end

      class DpRule
        sig { returns(T.nilable(Prism::Node)) }
        def condition; end

        sig { returns(T::Array[String]) }
        def enables; end

        sig { returns(T::Array[String]) }
        def prevents; end

        sig { returns(T::Boolean) }
        def prevent_all; end

        sig { params(value: T::Boolean).returns(T::Boolean) }
        def prevent_all=(value); end

        sig { returns(T::Boolean) }
        def unknown; end

        sig { params(value: T::Boolean).returns(T::Boolean) }
        def unknown=(value); end

        # [:enable or :prevent, the arguments as written], until read
        sig { returns(T::Array[[Symbol, T::Array[Prism::Node]]]) }
        def lists; end

        sig { params(value: T::Array[[Symbol, T::Array[Prism::Node]]]).returns(T::Array[[Symbol, T::Array[Prism::Node]]]) }
        def lists=(value); end

        sig { returns(String) }
        def file; end

        sig { returns(Integer) }
        def line; end

        sig { returns(String) }
        def owner; end

        sig do
          params(condition: T.nilable(Prism::Node), enables: T::Array[String], prevents: T::Array[String],
                 prevent_all: T::Boolean, unknown: T::Boolean, lists: T::Array[[Symbol, T::Array[Prism::Node]]],
                 file: String, line: Integer, owner: String).void
        end
        def initialize(condition:, enables:, prevents:, prevent_all:, unknown:, lists:, file:, line:, owner:); end

        sig { returns(String) }
        def location; end
      end

      class Delegate
        sig { returns(T.nilable(Prism::Node)) }
        def body; end

        sig { returns(String) }
        def file; end

        sig { returns(Integer) }
        def line; end

        sig { returns(String) }
        def owner; end

        sig { params(body: T.nilable(Prism::Node), file: String, line: Integer, owner: String).void }
        def initialize(body:, file:, line:, owner:); end
      end

      DECLARATIONS = T.let(T.unsafe(nil), T::Array[Symbol])

      sig { params(name: String).returns(T::Boolean) }
      def declarative?(name); end

      sig { params(class_name: String, name: String).returns(T.nilable(Condition)) }
      def condition_named(class_name, name); end

      sig { params(class_name: String).returns(T::Array[DpRule]) }
      def dp_rules(class_name); end

      sig { params(class_name: String).returns(T::Array[Delegate]) }
      def delegates(class_name); end

      sig { params(class_name: String, ability: String).returns(T::Boolean) }
      def overridden?(class_name, ability); end

      private

      sig { params(scope: Scope, call: Prism::CallNode, file: String).void }
      def declarative(scope, call, file); end

      sig { params(call: Prism::CallNode).void }
      def pending_scope(call); end

      sig { params(scope: Scope, call: Prism::CallNode, file: String).void }
      def condition(scope, call, file); end

      sig { params(scope: Scope, call: Prism::CallNode, file: String).void }
      def delegate(scope, call, file); end

      sig { params(scope: Scope, call: Prism::CallNode, file: String).void }
      def dp_rule(scope, call, file); end

      sig { params(entry: DpRule, call: Prism::CallNode).void }
      def apply(entry, call); end

      sig { params(rule: DpRule, class_name: String).void }
      def read_lists(rule, class_name); end

      sig do
        params(owner: String, args: T::Array[Prism::Node], bindings: T::Hash[String, String])
          .returns(T.nilable(T::Array[String]))
      end
      def abilities(owner, args, bindings); end

      sig do
        params(owner: String, node: Prism::Node, bindings: T::Hash[String, String])
          .returns(T.nilable(T::Array[String]))
      end
      def ability_names(owner, node, bindings); end

      sig do
        params(node: Prism::InterpolatedSymbolNode, bindings: T::Hash[String, String])
          .returns(T.nilable(T::Array[String]))
      end
      def interpolated(node, bindings); end

      sig do
        params(owner: String, call: Prism::CallNode, bindings: T::Hash[String, String])
          .returns(T.nilable(T::Array[String]))
      end
      def helper_abilities(owner, call, bindings); end

      sig do
        params(method: Prism::DefNode, call: Prism::CallNode, bindings: T::Hash[String, String])
          .returns(T.nilable(T::Hash[String, String]))
      end
      def bind_symbols(method, call, bindings); end

      sig { params(arg: T.nilable(Prism::Node), bindings: T::Hash[String, String]).returns(T.nilable(String)) }
      def bound_value(arg, bindings); end
    end
  end
end
