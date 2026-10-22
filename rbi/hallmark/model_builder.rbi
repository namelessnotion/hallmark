# typed: strict

module Hallmark
  class ModelBuilder
    class Model
      sig { returns(String) }
      def source; end

      # Exposures keyed by check name
      sig { returns(T::Hash[String, AnyExposure]) }
      def checks; end

      sig { returns(Analysis) }
      def analysis; end

      sig { params(source: String, checks: T::Hash[String, AnyExposure], analysis: Analysis).void }
      def initialize(source:, checks:, analysis:); end
    end

    sig { params(analysis: Analysis, scope: T.any(Integer, String)).void }
    def initialize(analysis, scope: Hallmark.configuration.scope)
      @analysis = T.let(T.unsafe(nil), Analysis)
      @scope = T.let(T.unsafe(nil), Integer)
    end

    sig { returns(Model) }
    def build; end

    sig { returns(String) }
    def source; end

    sig { returns(String) }
    def scope_clause; end

    private

    sig { returns(Mapping) }
    def mapping; end

    sig { returns(String) }
    def header; end

    sig { returns(String) }
    def tenancy; end

    sig { params(tenancy: Mapping::Tenancy).returns(String) }
    def tenancy_comment(tenancy); end

    sig { params(tenancy: Mapping::Tenancy).returns(T::Array[String]) }
    def tenancy_facts(tenancy); end

    sig { returns(String) }
    def roles; end

    sig { returns(T::Array[String]) }
    def role_names; end

    sig { returns(T::Boolean) }
    def checks_admin?; end

    sig { returns(String) }
    def grants; end

    sig { returns(T::Array[Mapping::Resource]) }
    def used_resources; end

    sig { returns(String) }
    def resources; end

    sig { returns(T::Array[String]) }
    def flags; end

    sig { params(resource: Mapping::Resource).returns(String) }
    def resource_comment(resource); end

    sig { params(resource: Mapping::Resource).returns(T.nilable(String)) }
    def publicity(resource); end

    sig { params(resource: Mapping::Resource).returns(T::Array[String]) }
    def resource_facts(resource); end

    sig { params(resource: Mapping::Resource).returns(T::Array[String]) }
    def tenant_facts(resource); end

    sig { returns(String) }
    def permits; end

    sig { returns(String) }
    def owner_outside; end

    sig { params(resource: Mapping::Resource).returns(String) }
    def owner_outside_fact(resource); end

    sig { params(op: Symbol).returns(String) }
    def op_sig(op); end

    sig { returns(String) }
    def exposures; end

    sig { params(exposure: Exposure).returns(String) }
    def exposure_block(exposure); end

    sig { returns(T.nilable(GraphqlModel)) }
    def graphql_model; end

    sig { returns(T::Array[Guard]) }
    def graphql_guards; end

    sig { returns(String) }
    def graphql; end

    sig { params(check: GraphqlCheck, model: GraphqlModel, tenancy: T::Boolean).returns(String) }
    def graphql_block(check, model, tenancy); end

    # The comment and the field's policy AND the restrictions covering it
    sig { params(check: GraphqlCheck).returns([String, String]) }
    def field_intended(check); end

    # The model comment and the formula the exposure's guard must imply
    sig { params(exposure: AnyExposure, op: String).returns([String, String]) }
    def intended(exposure, op); end

    sig { params(exposure: AnyExposure).returns(T::Boolean) }
    def current_tenant_list?(exposure); end

    # The catalog's `allowed`, or that OR the public action, with its comment
    sig { params(exposure: AnyExposure, op: String).returns([String, String]) }
    def record_intended(exposure, op); end
  end
end
