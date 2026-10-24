# typed: strict

module Hallmark
  class Extractor
    class RoleReads
      private

      sig { params(klass: T.nilable(String), name: String).returns(T.nilable([String, String])) }
      def delegated(klass, name); end

      sig { params(call: SourceIndex::Call, name: String).returns(T.nilable([String, String])) }
      def delegation(call, name); end

      sig { params(option: T.nilable(Prism::Node), target: String).returns(String) }
      def delegate_prefix(option, target); end

      sig { params(klass: String, target: String).returns(T.nilable(String)) }
      def delegate_target(klass, target); end

      sig { params(klass: T.nilable(String), name: String, depth: Integer).returns(T.nilable(String)) }
      def returned_class(klass, name, depth); end

      sig { params(call: Prism::CallNode, owner: T.nilable(String), depth: Integer).returns(T.nilable(String)) }
      def built_class(call, owner, depth); end

      sig { params(method: SourceIndex::Method).returns(T.untyped) }
      def last_expression(method); end
    end
  end
end
