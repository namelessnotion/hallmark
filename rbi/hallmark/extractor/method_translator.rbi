# typed: strict

module Hallmark
  class Extractor
    class MethodTranslator
      EXITS = T.let(T.unsafe(nil), T::Array[Symbol])
      COMPARISONS = T.let(T.unsafe(nil), T::Array[Symbol])
      QUERIES = T.let(T.unsafe(nil), T::Array[Symbol])

      class Frame
        # Nil inside a DeclarativePolicy condition block
        sig { returns(T.nilable(SourceIndex::Method)) }
        def definition; end

        sig { returns(String) }
        def file; end

        sig { returns(String) }
        def klass; end

        sig { returns(Locals) }
        def locals; end

        sig { params(locals: Locals).returns(Locals) }
        def locals=(locals); end

        sig { returns(T.nilable(Block)) }
        def block; end

        sig do
          params(definition: T.nilable(SourceIndex::Method), file: String, klass: String, locals: Locals,
                 block: T.nilable(Block)).void
        end
        def initialize(definition:, file:, klass:, locals:, block: nil); end
      end

      class Block
        sig { returns(T.nilable(Prism::Node)) }
        def body; end

        sig { returns(Frame) }
        def frame; end

        sig { params(body: T.nilable(Prism::Node), frame: Frame).void }
        def initialize(body:, frame:); end
      end

      sig { params(index: SourceIndex, terms: Terms).void }
      def initialize(index, terms)
        @index = T.let(T.unsafe(nil), SourceIndex)
        @terms = T.let(T.unsafe(nil), Terms)
        @stack = T.let(T.unsafe(nil), T::Array[[String, String]])
        @resource = T.let(T.unsafe(nil), T.nilable(String))
        @aliases = T.let(T.unsafe(nil), T::Hash[String, String])
      end

      sig { params(class_name: String, rule: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def rule(class_name, rule, resource); end

      sig do
        params(node: Prism::Node, method: SourceIndex::Method, class_name: String, resource: T.nilable(String),
               locals: Locals, aliases: T::Hash[String, String]).returns(Guard)
      end
      def expression(node, method, class_name, resource, locals: {}, aliases: {}); end

      sig do
        params(node: T.nilable(Prism::Node), file: String, class_name: String, resource: T.nilable(String), key: String,
               aliases: T::Hash[String, String]).returns(Guard)
      end
      def condition(node, file, class_name, resource, key:, aliases:); end

      private

      sig { params(class_name: String, rule: String).returns(T.nilable(SourceIndex::Method)) }
      def fallback(class_name, rule); end

      sig { params(class_name: String, rule: String, guard: Guard).returns(Guard) }
      def wrap_pre_checks(class_name, rule, guard); end

      sig { params(class_name: String, guard: Guard).returns(Guard) }
      def wrap_constructor(class_name, guard); end

      sig { params(method: SourceIndex::Method, class_name: String, rest: Guard).returns(Guard) }
      def body_guard(method, class_name, rest); end

      sig do
        params(method: SourceIndex::Method, class_name: String, locals: Locals, block: T.nilable(Block)).returns(Guard)
      end
      def method_guard(method, class_name, locals, block); end

      sig do
        params(method: SourceIndex::Method, class_name: String, locals: Locals, block: T.nilable(Block),
               blk: T.proc.params(frame: Frame).returns(Guard)).returns(Guard)
      end
      def enter(method, class_name, locals, block, &blk); end

      sig { params(node: T.nilable(Prism::Node)).returns(T::Array[Prism::Node]) }
      def statements(node); end

      sig { params(list: T::Array[Prism::Node], frame: Frame, rest: T.nilable(Guard)).returns(Guard) }
      def sequence(list, frame, rest); end

      sig do
        params(node: Prism::Node, tail: T::Array[Prism::Node], frame: Frame, rest: T.nilable(Guard)).returns(Guard)
      end
      def statement(node, tail, frame, rest); end

      sig do
        params(node: T.any(Prism::IfNode, Prism::UnlessNode), tail: T::Array[Prism::Node], frame: Frame,
               rest: T.nilable(Guard), last: T::Boolean).returns(Guard)
      end
      def conditional(node, tail, frame, rest, last); end

      sig do
        params(node: T.any(Prism::IfNode, Prism::UnlessNode))
          .returns([T::Array[Prism::Node], T::Array[Prism::Node]])
      end
      def branches(node); end

      sig { params(list: T::Array[Prism::Node]).returns(T::Boolean) }
      def exits?(list); end

      sig { params(node: Prism::Node).returns(T.nilable(Prism::CallNode)) }
      def exit_call(node); end

      sig { params(node: Prism::CallNode).returns(Guard) }
      def exit_value(node); end

      sig { params(node: Prism::ReturnNode, frame: Frame).returns(Guard) }
      def returned(node, frame); end

      sig { params(node: Prism::Node, frame: Frame).returns(Guard) }
      def value(node, frame); end

      sig { params(node: Prism::LocalVariableReadNode, frame: Frame).returns(Guard) }
      def local(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def call(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(Guard)) }
      def operator(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(Guard)) }
      def attribute(node, frame); end

      sig { params(node: Prism::CallNode).returns(T.nilable(String)) }
      def symbol_argument(node); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def comparison(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(Guard)) }
      def sibling(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(Guard)) }
      def query(node, frame); end

      sig { params(method: SourceIndex::Method, node: Prism::CallNode, frame: Frame).returns(Locals) }
      def bind(method, node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T.nilable(Block)) }
      def block_of(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(T::Boolean) }
      def block_call?(node, frame); end

      sig { params(node: Prism::Node, frame: Frame).returns(Guard) }
      def yielded(node, frame); end

      sig { params(frame: Frame).returns(Guard) }
      def super_call(frame); end

      sig { params(node: Prism::Node, frame: Frame).returns(Guard) }
      def term(node, frame); end

      sig { params(node: Prism::Node, frame: Frame).returns(String) }
      def render(node, frame); end

      sig { params(node: Prism::Node, frame: Frame).returns(Guard) }
      def opaque(node, frame); end

      sig { params(name: String, location: T.nilable(String)).returns(Guard) }
      def opaque_named(name, location = nil); end

      sig { returns(Guard) }
      def never; end
    end
  end
end
