# typed: strict
# frozen_string_literal: true

module Hallmark
  # A counterexample translated back into application terms: who can do what
  # to which record, and which catalog pattern the developer most likely
  # meant to implement.
  class Finding
    # A tenant in the witness, the user it is when tenants are users, and the
    # roles the principal holds in it.
    TenantRoles = Struct.new(:tenant, :user, :roles, keyword_init: true)

    attr_reader :exposure, :principal, :record, :owner, :roles, :current_tenant, :record_tenant

    def self.from(exposure, instance, mapping)
      check = exposure.check_name
      principal = instance.skolem("$#{check}_p")
      record = instance.skolem("$#{check}_r")
      raise SolverError, "counterexample for #{exposure.action} has no witness" unless principal && record

      new(
        exposure: exposure,
        mapping: mapping,
        principal: principal,
        record: record,
        owner: instance.field(record, "owner").first,
        roles: instance.field(principal, "assigned"),
        current_tenant: tenant_roles(instance, principal, instance.skolem("$#{check}_cur")),
        record_tenant: tenant_roles(instance, principal, instance.field(record, "tenant").first)
      )
    end

    def self.tenant_roles(instance, principal, tenant)
      return nil unless tenant

      memberships = instance.sources("member", principal).select do |membership|
        instance.field(membership, "within").include?(tenant)
      end
      TenantRoles.new(
        tenant: tenant,
        user: instance.field(tenant, "user").first,
        roles: memberships.flat_map { |membership| instance.field(membership, "roles") }.map { role_name(_1) }
      )
    end

    # "catalog/Role_admin$0" or "Role_admin" -> "admin"
    def self.role_name(atom) = Naming.atom(atom).sub(/\$\d+\z/, "").delete_prefix("Role_")

    def initialize(exposure:, mapping:, principal:, record:, owner:, roles:, current_tenant: nil, record_tenant: nil)
      @exposure = exposure
      @mapping = mapping
      @resource = mapping.fetch(exposure.resource)
      @principal = principal
      @record = record
      @owner = owner
      @roles = roles.map { |role| Finding.role_name(role) }
      @current_tenant = current_tenant
      @record_tenant = record_tenant
    end

    def anonymous? = Naming.atom(principal).start_with?("Anonymous")
    def own_record? = !owner.nil? && owner == principal

    # The record lives in a different tenant from the one the request acts for.
    def cross_tenant?
      current = current_tenant
      target = record_tenant
      !current.nil? && !target.nil? && current.tenant != target.tenant
    end

    # The pattern the guard was most likely meant to implement, following the
    # SPACE classification of bugs by violated pattern.
    def pattern
      return "Authentication" if anonymous?
      return "Explicit permission" if exposure.guard.roles.any?
      return "User profiles" if @resource.kind == :profile
      return "Ownership" if @resource.owned?

      "Explicit permission"
    end

    def message
      "#{who} can #{verb} #{what}"
    end

    # A next step when the fix may be in the code's tenant check or in the
    # mapping rather than in the guard's roles.
    def hint
      return nil if anonymous?
      if cross_tenant?
        return "the #{@resource.name} is not in the current tenant; check that it belongs to the tenant " \
               "the request acts for"
      end

      roles = exposure.guard.roles
      return nil if roles.empty?

      declarations = roles.map { |role| "grant :#{role}, :#{exposure.op}, \"#{exposure.resource}\"" }
      "if this is intended, declare it in the map block: #{declarations.join(" / ")}"
    end

    private

    def who
      return "an anonymous visitor" if anonymous?

      base = "a signed-in #{@mapping.principal_name} (#{user_label(principal)})"
      current = current_tenant
      return "#{base} holding #{held(roles)}" unless current

      own = " (their own)" if current.user == principal
      outside = " and #{held(roles)} outside any tenant" if roles.any?
      "#{base} holding #{held(current.roles)} in the current tenant #{tenant_label(current)}#{own}#{outside}"
    end

    def held(names) = names.empty? ? "no roles" : "roles #{names.join(", ")}"

    def verb = exposure.op == :read ? "read" : "update"

    def what
      "#{record_label}#{where}"
    end

    def record_label
      if @resource.kind == :profile
        own_record? ? "their own profile" : "the #{@resource.name} profile of #{user_label(owner)}"
      elsif @resource.owned?
        own_record? ? "a #{@resource.name} they own" : "a #{@resource.name} owned by #{user_label(owner)}"
      else
        "a #{@resource.name} (#{Naming.atom(record)})"
      end
    end

    def where
      target = record_tenant
      return @resource.tenant_optional? ? " outside any tenant" : "" unless target
      return " in the current tenant" unless cross_tenant? || current_tenant.nil?
      return " in tenant #{tenant_label(target)}" if anonymous?

      " in tenant #{tenant_label(target)}, where they hold #{held(target.roles)}"
    end

    # Tenants that are users read as that user; others as the tenant class.
    def tenant_label(tenant_roles)
      return user_label(tenant_roles.user) if tenant_roles.user

      name = @mapping.tenancy&.name || "Tenant"
      "#{name}#{Naming.atom(tenant_roles.tenant).delete_prefix("Tenant")}"
    end

    def user_label(atom)
      "#{@mapping.principal_name}#{Naming.atom(atom).delete_prefix("User")}"
    end
  end
end
