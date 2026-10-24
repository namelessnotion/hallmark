# typed: strict

module Hallmark
  class Extractor
    class GraphqlFieldClasses
      CONTEXT = T.let(T.unsafe(nil), Regexp)
      FIELD_NAME = T.let(T.unsafe(nil), Regexp)
      RESOLVE = T.let(T.unsafe(nil), T::Array[String])
      MAX_BINDINGS = T.let(T.unsafe(nil), Integer)

      # A context key's value in one reading: a literal's text, or nil
      Binding = T.type_alias { T::Hash[String, T.nilable(String)] }

      sig do
        params(index: SourceIndex, translator: MethodTranslator, policies: Extractor,
               aliases: T::Hash[String, String], cleanup: T.proc.params(guard: Guard).returns(Guard)).void
      end
      def initialize(index, translator, policies, aliases:, cleanup:)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @translator = T.let(T.unsafe(nil), MethodTranslator)
        @policies = T.let(T.unsafe(nil), Extractor)
        @aliases = T.let(T.unsafe(nil), T::Hash[String, String])
        @cleanup = T.let(T.unsafe(nil), T.proc.params(guard: Guard).returns(Guard))
        @assigned = T.let(T.unsafe(nil), T.nilable(T::Hash[String, T::Array[T.nilable(String)]]))
      end

      sig { params(call: SourceIndex::Call, name: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def guard(call, name, resource); end

      sig { params(name: String).returns(T.nilable(String)) }
      def field_class(name); end

      sig { returns(T::Hash[String, T::Array[T.nilable(String)]]) }
      def assigned; end

      private

      sig { params(owner: String).returns(T.nilable(SourceIndex::Method)) }
      def check_method(owner); end

      sig { params(owner: String).returns(T.nilable(String)) }
      def default_class(owner); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def param(node); end

      sig { params(record: T.nilable(String), context: T.nilable(String)).returns(T::Hash[String, String]) }
      def aliases_for(record, context); end

      sig { params(method: SourceIndex::Method, context: T.nilable(String)).returns(T::Array[Binding]) }
      def bindings(method, context); end

      sig { params(node: Prism::Node, context: String).returns(T::Array[String]) }
      def read_keys(node, context); end

      sig do
        params(method: SourceIndex::Method, name: String, resource: T.nilable(String),
               aliases: T::Hash[String, String], binding: Binding).returns(Guard)
      end
      def read(method, name, resource, aliases, binding); end

      sig do
        params(klass: String, name: String, resource: T.nilable(String), binding: Binding)
          .returns(MethodTranslator::Resolver)
      end
      def resolver(klass, name, resource, binding); end

      sig do
        params(node: Prism::CallNode, render: T.proc.params(node: Prism::Node).returns(String), binding: Binding)
          .returns(T.nilable(Guard))
      end
      def nil_check(node, render, binding); end

      sig do
        params(node: Prism::CallNode, render: T.proc.params(node: Prism::Node).returns(String), binding: Binding)
          .returns(T.nilable(Guard))
      end
      def bound(node, render, binding); end

      sig do
        params(node: Prism::CallNode, render: T.proc.params(node: Prism::Node).returns(String), klass: String,
               name: String).returns(T.nilable(Guard))
      end
      def open_field(node, render, klass, name); end

      sig { params(receiver: T.nilable(Prism::Node), klass: String).returns(T.nilable(T::Array[String])) }
      def constant_names(receiver, klass); end

      sig do
        params(node: Prism::CallNode, render: T.proc.params(node: Prism::Node).returns(String),
               resource: T.nilable(String), binding: Binding).returns(T.nilable(Guard))
      end
      def permission(node, render, resource, binding); end

      sig do
        params(node: Prism::CallNode, render: T.proc.params(node: Prism::Node).returns(String))
          .returns(T.nilable(Prism::Node))
      end
      def on_record(node, render); end

      sig do
        params(node: Prism::Node, render: T.proc.params(node: Prism::Node).returns(String), binding: Binding)
          .returns(T.nilable(String))
      end
      def ability_of(node, render, binding); end

      sig { params(node: Prism::Node).returns(T::Array[[String, Prism::Node]]) }
      def assignments(node); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Boolean) }
      def context_reader?(node); end

      sig do
        params(found: T::Hash[String, T::Array[T.nilable(String)]], unread: T::Array[String], key: String,
               node: Prism::Node).void
      end
      def record_value(found, unread, key, node); end

      sig { params(node: T.nilable(Prism::Node)).returns(T.nilable(String)) }
      def literal(node); end

      sig { params(node: T.nilable(Prism::Node), block: T.proc.params(node: Prism::CallNode).void).void }
      def walk(node, &block); end
    end
  end
end
