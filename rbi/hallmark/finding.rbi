# typed: strict

module Hallmark
  class Finding
    class TenantRoles
      # Alloy atom, such as "catalog/Tenant$0"
      sig { returns(String) }
      def tenant; end

      # The user the tenant is, when tenants are users
      sig { returns(T.nilable(String)) }
      def user; end

      # Role names the principal holds in the tenant
      sig { returns(T::Array[String]) }
      def roles; end

      sig { params(tenant: String, user: T.nilable(String), roles: T::Array[String]).void }
      def initialize(tenant:, user:, roles:); end
    end

    sig { returns(AnyExposure) }
    attr_reader :exposure

    # Alloy atoms, such as "catalog/User$0"
    sig { returns(String) }
    attr_reader :principal

    sig { returns(String) }
    attr_reader :record

    sig { returns(T.nilable(String)) }
    attr_reader :owner

    # Role names without the "Role_" prefix
    sig { returns(T::Array[String]) }
    attr_reader :roles

    sig { returns(T.nilable(TenantRoles)) }
    attr_reader :current_tenant

    sig { returns(T.nilable(TenantRoles)) }
    attr_reader :record_tenant

    # For a GraphQL check, the query that reaches the witness
    sig { returns(T.nilable(String)) }
    attr_reader :path

    # The resource's flags and whether the witness record has each
    sig { returns(T::Hash[String, T::Boolean]) }
    attr_reader :flags

    sig { params(exposure: AnyExposure, instance: Receipt::Instance, mapping: Mapping).returns(Finding) }
    def self.from(exposure, instance, mapping); end

    sig { params(exposure: AnyExposure, mapping: Mapping).returns(T::Boolean) }
    def self.current_tenant?(exposure, mapping); end

    sig do
      params(instance: Receipt::Instance, principal: String, tenant: T.nilable(String)).returns(T.nilable(TenantRoles))
    end
    def self.tenant_roles(instance, principal, tenant); end

    sig { params(atom: String).returns(String) }
    def self.role_name(atom); end

    sig do
      params(
        exposure: AnyExposure,
        mapping: Mapping,
        principal: String,
        record: String,
        owner: T.nilable(String),
        roles: T::Array[String],
        current_tenant: T.nilable(TenantRoles),
        record_tenant: T.nilable(TenantRoles),
        flags: T::Hash[String, T::Boolean],
        path: T.nilable(String)
      ).void
    end
    def initialize(exposure:, mapping:, principal:, record:, owner:, roles:, current_tenant: nil, record_tenant: nil,
                   flags: {}, path: nil)
      @exposure = T.let(T.unsafe(nil), AnyExposure)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @resource = T.let(T.unsafe(nil), Mapping::Resource)
      @principal = T.let(T.unsafe(nil), String)
      @record = T.let(T.unsafe(nil), String)
      @owner = T.let(T.unsafe(nil), T.nilable(String))
      @roles = T.let(T.unsafe(nil), T::Array[String])
      @current_tenant = T.let(T.unsafe(nil), T.nilable(TenantRoles))
      @record_tenant = T.let(T.unsafe(nil), T.nilable(TenantRoles))
      @flags = T.let(T.unsafe(nil), T::Hash[String, T::Boolean])
      @path = T.let(T.unsafe(nil), T.nilable(String))
      @witness = T.let(T.unsafe(nil), T.nilable(WitnessFacts))
    end

    sig { returns(T::Boolean) }
    def anonymous?; end

    sig { returns(T::Boolean) }
    def own_record?; end

    sig { returns(T::Boolean) }
    def cross_tenant?; end

    sig { returns(String) }
    def pattern; end

    sig { returns(String) }
    def message; end

    # A list of a resource mapped `lists: :current_tenant` showing another tenant's record
    sig { returns(T::Boolean) }
    def list_across_tenants?; end

    sig { returns(T.nilable(String)) }
    def hint; end

    # The covering restriction the witness breaks, read from the witness
    sig { returns(T.nilable(Restriction)) }
    def restriction; end

    sig { returns(T.nilable(Mapping::FieldPolicy)) }
    def field_policy; end

    sig { returns(T::Boolean) }
    def field_policy_broken?; end

    # The field policy and covering restrictions, when the witness plainly breaks neither
    sig { returns(T.nilable(String)) }
    def intended; end

    private

    sig { returns(WitnessFacts) }
    def witness; end

    sig { returns(T.nilable(String)) }
    def narrowing_hint; end

    sig { params(shown: String).returns(String) }
    def serializer_hint(shown); end

    sig { returns(String) }
    def listed_across_tenants; end

    sig { returns(String) }
    def list_tenant_hint; end

    sig { returns(String) }
    def reason; end

    sig { returns(T.nilable(String)) }
    def way_in; end

    sig { returns(String) }
    def declared_pattern; end

    sig { returns(T::Boolean) }
    def owner_outside?; end

    sig { returns(String) }
    def graphql_hint; end

    sig { params(key: String).returns(T::Array[String]) }
    def graphql_declarations(key); end

    sig { returns(String) }
    def owner_hint; end

    sig { returns(T.nilable(String)) }
    def public_hint; end

    sig { returns(T::Boolean) }
    def signed_in_only?; end

    sig { params(rules: T::Array[String], signed_in: T::Boolean).returns(T::Array[String]) }
    def public_declarations(rules, signed_in); end

    sig { returns(String) }
    def who; end

    sig { returns(T::Array[String]) }
    def held_anywhere; end

    sig { params(names: T::Array[String]).returns(String) }
    def held(names); end

    sig { returns(String) }
    def verb; end

    sig { returns(String) }
    def what; end

    sig { returns(String) }
    def record_label; end

    sig { returns(String) }
    def a_resource; end

    sig { returns(String) }
    def where; end

    sig { returns(String) }
    def flag_list; end

    sig { params(tenant_roles: TenantRoles).returns(String) }
    def tenant_label(tenant_roles); end

    sig { params(atom: T.nilable(String)).returns(String) }
    def user_label(atom); end
  end
end
