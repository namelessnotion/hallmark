# typed: strict

module Hallmark
  class Extractor
    class RoleReads
      private

      sig { params(rules: T::Array[Extracted]).void }
      def read_starts(rules); end

      sig { params(label: String, source: Collectors::Source, classes: T::Array[String]).void }
      def reader_start(label, source, classes); end

      sig { params(label: String, source: Proc, classes: T::Array[String]).void }
      def lambda_start(label, source, classes); end

      sig { params(file: String, line: T.nilable(Integer)).returns(T.untyped) }
      def lambda_at(file, line); end

      sig { params(root: Prism::Node).returns(T::Array[Prism::Node]) }
      def all_nodes(root); end

      sig { params(node: Prism::Node).returns(T::Boolean) }
      def lambda_node?(node); end

      sig { params(node: Prism::Node).returns(T.untyped) }
      def lambda_body(node); end

      sig { params(node: T.untyped).returns(T::Array[String]) }
      def parameter_names(node); end

      sig { params(source: String).void }
      def term_start(source); end

      sig { params(rule: Extracted).void }
      def rule_start(rule); end

      sig { params(policy: String, condition: SourceIndex::Condition, env: T::Hash[String, String]).void }
      def condition_start(policy, condition, env); end

      sig { returns(T::Hash[String, String]) }
      def user_env; end

      sig { params(resource: T.nilable(String)).returns(T::Hash[String, String]) }
      def record_env(resource); end

      sig { params(label: String).returns(Start) }
      def add_start(label); end
    end
  end
end
