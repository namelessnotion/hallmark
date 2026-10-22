# typed: strict

module Hallmark
  class Extractor
    class MethodTranslator
      KEEPING = T.let(T.unsafe(nil), T::Array[Symbol])

      class Relation
        sig { returns(T::Array[String]) }
        def roots; end

        sig { returns(T.nilable(String)) }
        def model; end

        sig { params(roots: T::Array[String], model: T.nilable(String)).void }
        def initialize(roots:, model:); end
      end

      sig do
        params(method: SourceIndex::Method, class_name: String, resource: T.nilable(String), roots: T::Array[String],
               aliases: T::Hash[String, String]).returns(Guard)
      end
      def scope(method, class_name, resource, roots:, aliases: {}); end

      sig do
        params(body: T.nilable(Prism::Node), file: String, class_name: String, resource: T.nilable(String),
               roots: T::Array[String]).returns(Guard)
      end
      def scope_block(body, file, class_name, resource, roots:); end

      private

      sig { params(roots: T::Array[String], blk: T.proc.returns(Guard)).returns(Guard) }
      def within_relation(roots, &blk); end

      sig { params(blk: T.proc.returns(Guard)).returns(Guard) }
      def outside_relation(&blk); end

      sig { params(node: Prism::Node, frame: Frame).returns(T.nilable(Guard)) }
      def relation_value(node, frame); end

      sig { params(node: Prism::Node, frame: Frame, relation: Relation).returns(T::Boolean) }
      def relational?(node, frame, relation); end

      sig { params(node: Prism::CallNode, relation: Relation).returns(T::Boolean) }
      def root_call?(node, relation); end

      sig { params(node: Prism::Node, relation: Relation).returns(T::Boolean) }
      def model?(node, relation); end

      sig { params(node: Prism::CallNode).returns(T::Boolean) }
      def association?(node); end

      sig { params(node: Prism::CallNode, frame: Frame, relation: Relation).returns(Guard) }
      def chain(node, frame, relation); end

      sig do
        params(node: Prism::CallNode, receiver: Prism::Node, frame: Frame, relation: Relation).returns(T.nilable(Guard))
      end
      def step_term(node, receiver, frame, relation); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def negated(node, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def argument_relation(node, frame); end

      sig { params(node: Prism::CallNode, receiver: Prism::Node, frame: Frame).returns(Guard) }
      def holder(node, receiver, frame); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def pairs(node, frame); end

      sig { params(pair: Prism::Node, frame: Frame).returns(T.nilable(Guard)) }
      def pair_guard(pair, frame); end

      sig { params(name: String, resource: T.nilable(String)).returns(T.nilable(Guard)) }
      def attribute_term(name, resource); end

      sig { params(node: Prism::CallNode, frame: Frame).returns(Guard) }
      def selected(node, frame); end

      sig { params(block: Prism::BlockNode).returns(T.nilable(String)) }
      def block_parameter(block); end

      sig { params(node: Prism::Node, frame: Frame, relation: Relation).returns(String) }
      def scope_source(node, frame, relation); end
    end
  end
end
