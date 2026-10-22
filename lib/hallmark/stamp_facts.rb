# typed: strict
# frozen_string_literal: true

module Hallmark
  # A stamp's facts read as guard leaves, for one mapped resource: the one
  # place that says what a stamp means in catalog terms. Inference builds
  # inferred guards from `literals`; drift evaluates extracted guards with
  # `Guard#evaluate`, which asks `[]` for each leaf.
  #
  # `[]` follows the model's facts where the mapping decides a leaf (a
  # resource with no owner is owned by no one, one never public is never
  # public, a record with no tenant is in no tenant and gives no roles), and
  # the stamp elsewhere. It answers nil, unknown, where the stamp holds no
  # such fact: an opaque call, the catalog's `admin` (stamps record role
  # names, not the catalog's Admin), a role held in some tenant other than
  # the two stamped, roles in the current tenant when the stamp saw none,
  # and any fact a stamp left nil.
  class StampFacts
    include Guard::DSL

    attr_reader :stamp, :resource

    def initialize(mapping, resource, stamp)
      @mapping = mapping
      @resource = resource
      @stamp = stamp
    end

    # The true facts as literals, which an allow-stamp contributes to the
    # inferred guard. Only true facts: the catalog allows more as a
    # principal gains roles, ownership or membership, so the false ones
    # change no verdict. Where the record lives is one literal, the most
    # specific; no membership literal, since holding a role in a tenant
    # implies membership there.
    def literals
      out = record_literals
      out << permitted if stamp.permitted && resource.permits?
      if @mapping.tenancy
        out.concat(record_tenant_literals) if resource.tenanted?
        current_roles.each { |name| out << role(name, tenant: :current) }
      end
      outside_roles.each { |name| out << role(name) }
      out
    end

    # Whether a leaf holds for this stamp: true, false or nil (unknown).
    def [](leaf)
      case leaf.kind
      when :none then true
      when :never then false
      when :logged_in then fact(stamp.logged_in)
      when :owner then resource.owned? ? fact(stamp.owner) : false
      when :public then public_fact
      when :permitted then resource.permits? ? fact(stamp.permitted) : false
      when :outside_tenants then outside_tenants_fact
      when :in_current_tenant then in_current_tenant_fact
      when :role then role_fact(leaf.operands[0].to_s, leaf.operands[1])
      end
    end

    # The stamp's facts on this resource, as `hallmark check` prints them:
    # "logged_in & ~owner & in_current_tenant & current_roles=[admin]".
    def to_s
      parts = record_labels
      parts.concat(tenant_labels) if @mapping.tenancy
      parts << "roles=[#{outside_roles.join(", ")}]" if outside_roles.any?
      parts.join(" & ")
    end

    private

    def record_literals
      out = []
      out << logged_in if stamp.logged_in
      out << public_record if stamp.public_record && resource.public? && !resource.always_public?
      out << owner if stamp.owner && resource.owned?
      out
    end

    # Where the record lives: outside tenants (a record with no tenant gets
    # `outside_tenants`, so that an owner's allow on a personal record does
    # not stand for records in a tenant), in the current tenant, or in
    # another, with the roles held there.
    def record_tenant_literals
      return [outside_tenants] if resource.tenant_optional? && stamp.outside_tenants
      return [in_current_tenant] if stamp.in_current_tenant

      record_roles.map { |name| role(name, tenant: :record) }
    end

    # Outside tenants users hold only platform roles (docs/PLAN.md).
    def outside_roles
      roles = names(stamp.roles)
      @mapping.tenancy ? roles & @mapping.platform_roles : roles
    end

    def record_roles = names(stamp.record_roles)
    def current_roles = names(stamp.current_roles)
    def names(value) = Array(value).map(&:to_s).sort

    def fact(value) = value.nil? ? nil : value == true

    def public_fact
      return true if resource.always_public?
      return false unless resource.public?

      fact(stamp.public_record)
    end

    # Without a tenant in the mapping, every record lives outside tenants.
    def outside_tenants_fact
      return true unless @mapping.tenancy && resource.tenanted?
      return false unless resource.tenant_optional?

      fact(stamp.outside_tenants)
    end

    def in_current_tenant_fact
      outside = outside_tenants_fact
      return false if outside
      return nil if outside.nil?

      fact(stamp.in_current_tenant)
    end

    def role_fact(name, tenant)
      return false if stamp.logged_in == false

      case tenant
      when nil then outside_roles.include?(name)
      when :current then current_role_fact(name)
      when :record then record_role_fact(name)
      when :any then true if current_role_fact(name) || record_role_fact(name)
      end
    end

    # In the current tenant, the current tenant's roles are the record
    # tenant's when the stamp has no others.
    def current_role_fact(name)
      return nil unless @mapping.tenancy

      held = stamp.current_roles
      held = stamp.record_roles if held.nil? && in_current_tenant_fact
      held.nil? ? nil : names(held).include?(name)
    end

    # Some role in the record's tenant: what `member` records.
    def member_fact
      return false if stamp.logged_in == false

      outside = outside_tenants_fact
      return false if outside
      return nil if outside.nil? || stamp.record_roles.nil?

      record_roles.any?
    end

    def record_role_fact(name)
      outside = outside_tenants_fact
      return false if outside
      return nil if outside.nil? || stamp.record_roles.nil?

      record_roles.include?(name)
    end

    def record_labels
      parts = [label("logged_in", stamp.logged_in)]
      parts << label("public_record", stamp.public_record) if resource.public? && !resource.always_public?
      parts << label("owner", stamp.owner) if resource.owned?
      parts << label("permitted", stamp.permitted) if resource.permits?
      parts
    end

    def tenant_labels
      parts = []
      parts << label("outside_tenants", outside_tenants_fact) if resource.tenant_optional?
      if resource.tenanted? && !outside_tenants_fact
        parts << label("in_current_tenant", stamp.in_current_tenant)
        parts << "record_roles=[#{record_roles.join(", ")}]" unless stamp.record_roles.nil?
      end
      parts << "current_roles=[#{current_roles.join(", ")}]" unless stamp.current_roles.nil?
      parts
    end

    def label(name, value)
      return "#{name}=?" if value.nil?

      value ? name : "~#{name}"
    end
  end
end
