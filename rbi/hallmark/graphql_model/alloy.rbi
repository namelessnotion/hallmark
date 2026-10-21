# typed: strict

module Hallmark
  class GraphqlModel
    class Alloy
      sig { params(model: GraphqlModel, mapping: Mapping).void }
      def initialize(model, mapping)
        @model = T.let(T.unsafe(nil), GraphqlModel)
        @mapping = T.let(T.unsafe(nil), Mapping)
        @source = T.let(T.unsafe(nil), T::Hash[T::Boolean, String])
      end

      sig { params(tenancy: T::Boolean).returns(String) }
      def source(tenancy); end

      sig { params(check: GraphqlCheck, tenancy: T::Boolean).returns(String) }
      def quantifier(check, tenancy); end

      sig { params(check: GraphqlCheck, tenancy: T::Boolean).returns(String) }
      def field_read(check, tenancy); end

      private

      sig { returns(String) }
      def header; end

      sig { params(tenancy: T::Boolean, variable: String, type: String).returns(String) }
      def params(tenancy, variable, type); end

      sig { params(tenancy: T::Boolean, variable: String).returns(String) }
      def args(tenancy, variable); end

      sig { params(name: String, tenancy: T::Boolean, type: String, guard: Guard).returns(String) }
      def pred(name, tenancy, type, guard); end

      sig { params(type: String).returns(String) }
      def graphql_name(type); end

      sig { params(tenancy: T::Boolean).returns(T::Array[String]) }
      def root_preds(tenancy); end

      sig { params(tenancy: T::Boolean).returns(T::Array[String]) }
      def edge_preds(tenancy); end

      sig { params(tenancy: T::Boolean).returns(T::Array[String]) }
      def field_preds(tenancy); end

      sig { params(tenancy: T::Boolean).returns(T::Array[String]) }
      def tenant_facts(tenancy); end

      sig { params(type: String).returns(Mapping::Resource) }
      def resource(type); end

      sig { params(parent: Mapping::Resource, child: Mapping::Resource).returns(T::Boolean) }
      def same_tenant?(parent, child); end

      sig { params(tenancy: T::Boolean).returns(T::Array[String]) }
      def funs(tenancy); end

      sig { params(name: String, own: String, tenancy: T::Boolean).returns(T::Array[String]) }
      def type_funs(name, own, tenancy); end

      sig { params(parts: T::Array[String], empty: String).returns(String) }
      def union(parts, empty); end

      sig { params(name: String).returns(String) }
      def id(name); end
    end
  end
end
