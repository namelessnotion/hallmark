# typed: strict
# frozen_string_literal: true

module Hallmark
  # A counterexample translated back into application terms: who can do what
  # to which record, and which catalog pattern the developer most likely
  # meant to implement.
  class Finding
    # The catalog's explicit permission through a role (`grant`), as opposed
    # to a permit on one record (`permits:`).
    ROLE_GRANT = "Explicit permission (a grant to a role)"

    # A tenant in the witness, the user it is when tenants are users, and the
    # roles the principal holds in it.
    TenantRoles = Struct.new(:tenant, :user, :roles, keyword_init: true)

    # `path` is, for a GraphQL check, the query a client would send to
    # reach the witness (`GraphqlModel#path`); nil otherwise.
    attr_reader :exposure, :principal, :record, :owner, :roles, :current_tenant, :record_tenant, :flags, :path

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
        current_tenant: (tenant_roles(instance, principal, instance.skolem("$#{check}_cur")) if
          current_tenant?(exposure, mapping)),
        record_tenant: tenant_roles(instance, principal, instance.field(record, "tenant").first),
        flags: mapping.fetch(exposure.resource).flags.to_h do |name|
          [name, instance.sources(Naming.flag_field(name), record).any?]
        end,
        path: exposure.is_a?(GraphqlCheck) ? exposure.path(instance) : nil
      )
    end

    # A tenant-aware witness always has a current tenant, but it means
    # something only when the map block declares one or the guard (or the
    # field's policy) reads it.
    def self.current_tenant?(exposure, mapping)
      policy = mapping.field_policy_for(exposure.resource, exposure.field)
      !(mapping.current_tenant_source || mapping.current_tenant_controller).nil? ||
        exposure.guard.tenants.include?(:current) || (!policy.nil? && policy.guard.tenants.include?(:current))
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

    def initialize(exposure:, mapping:, principal:, record:, owner:, roles:, current_tenant: nil, record_tenant: nil,
                   flags: {}, path: nil)
      @exposure = exposure
      @mapping = mapping
      @resource = mapping.fetch(exposure.resource)
      @principal = principal
      @record = record
      @owner = owner
      @roles = roles.map { |role| Finding.role_name(role) }
      @current_tenant = current_tenant
      @record_tenant = record_tenant
      @flags = flags
      @path = path
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
    # SPACE classification of bugs by violated pattern: first the way the
    # witness got in, then what the guard and the mapping offer.
    def pattern
      return "Authentication" if anonymous?
      return "User profiles" if @resource.kind == :profile

      way_in || declared_pattern
    end

    def message
      "#{who} can #{verb} #{what}#{reason}"
    end

    # The covering restriction the witness breaks: it holds a denied role
    # where the role counts, on a record the denial's condition does not
    # rule out. Read from the witness, not the solver.
    def restriction
      @mapping.restrictions_for(exposure).find do |restriction|
        restriction.covering(exposure).any? { |denial| witness.denied?(denial) }
      end
    end

    # The field's policy, when the exposure reads a field that has one.
    def field_policy = @mapping.field_policy_for(exposure.resource, exposure.field)

    # Whether the witness falls outside the field's policy, as far as the
    # witness says (an unknown term never counts).
    def field_policy_broken?
      policy = field_policy
      !policy.nil? && witness.evaluate(policy.guard) == false
    end

    # When neither a restriction nor the field's policy is plainly what the
    # witness breaks, what else the check asked for besides the catalog:
    # the field's policy and every covering restriction.
    def intended
      return nil if restriction || field_policy_broken?

      parts = []
      if (policy = field_policy)
        parts << "field policy for #{policy.key}: #{policy.guard}"
      end
      @mapping.restrictions_for(exposure).each do |restriction|
        parts << "restriction #{restriction.name.inspect} (#{restriction.covering(exposure).join("; ")})"
      end
      parts.empty? ? nil : parts.join("; ")
    end

    # A next step when the fix may be in the code's tenant check or in the
    # mapping rather than in the guard's roles.
    def hint
      if (narrowed = narrowing_hint)
        return narrowed
      end
      return graphql_hint if exposure.is_a?(GraphqlCheck)
      return public_hint if anonymous?
      return owner_hint if owner_outside?
      if cross_tenant?
        return "the #{@resource.name} is not in the current tenant; check that it belongs to the tenant " \
               "the request acts for"
      end

      roles = exposure.guard.roles
      return public_hint if roles.empty?

      declarations = roles.map { |role| "grant :#{role}, :#{exposure.op}, \"#{exposure.resource}\"" }
      "if this is intended, declare it in the map block: #{declarations.join(" / ")}"
    end

    private

    def witness = @witness ||= WitnessFacts.new(self, @mapping.platform_roles)

    # The next step when a restriction or the field's policy is what the
    # witness breaks.
    def narrowing_hint
      if (broken = restriction)
        roles = broken.covering(exposure).select { |denial| witness.denied?(denial) }.map { |denial| ":#{denial.role}" }
        "exclude holders of #{roles.uniq.join(", ")} in the code, or narrow the restriction " \
          "#{broken.name.inspect} if this is intended"
      elsif field_policy_broken?
        "check the code that decides whether #{exposure.target} is shown, or widen its field policy " \
          "in the map block if this is intended"
      end
    end

    # Why the check fails beyond the catalog, for the message.
    def reason
      if (broken = restriction)
        ", which the restriction #{broken.name.inspect} forbids"
      elsif field_policy_broken? && (policy = field_policy)
        ", which its field policy allows only where #{policy.guard}"
      else
        ""
      end
    end

    # The guard's way in that the witness took: as the owner, or through a
    # role it holds.
    def way_in
      guard = exposure.guard
      return "Ownership" if own_record? && guard.leaves.any? { |leaf| leaf.kind == :owner }

      ROLE_GRANT if guard.roles.intersect?(held_anywhere)
    end

    def declared_pattern
      guard = exposure.guard
      return "Explicit permission on a record" if guard.permits?
      return "Ownership" if @resource.owned?
      return ROLE_GRANT if guard.roles.any?
      return ROLE_GRANT if exposure.is_a?(GraphqlCheck) && @mapping.grants.any? { |g| g.resource == @resource.name }

      "Public actions"
    end

    # The owner reaches their record in a tenant where they hold no role,
    # through the guard's ownership check.
    def owner_outside?
      target = record_tenant
      own_record? && !target.nil? && target.roles.empty? && @resource.owner_outside_ops.empty? &&
        exposure.guard.leaves.any? { |leaf| leaf.kind == :owner }
    end

    # Every way to an object of a GraphQL type passes the type's
    # `authorized?`, so that is where a check closes all of them; or the
    # access is intended, and the map block should say so.
    def graphql_hint
      key = exposure.rules&.first.to_s
      where = exposure.locations&.first
      "every way to #{a_resource} through GraphQL passes #{key.sub("#", ".")}#{" (#{where})" if where}; check the " \
        "object there, or if this is intended, declare it in the map block: #{graphql_declarations(key).join(" / ")}"
    end

    # A grant for each role the witness holds in the record's tenant, else
    # a public action on the type check.
    def graphql_declarations(key)
      held = record_tenant&.roles || []
      return held.map { |role| "grant :#{role}, :read, \"#{exposure.resource}\"" } unless anonymous? || held.empty?

      ["public_action \"#{key.split("#").first}\", :authorized?#{", audience: :signed_in" unless anonymous?}"]
    end

    def owner_hint
      "if its owner may #{verb} it without being a member of its tenant, declare it in the map block: " \
        "resource \"#{@resource.name}\", ..., owner_outside_tenant: :#{exposure.op}"
    end

    # For a guard that checks no role and no ownership, on rules the
    # exposure names.
    def public_hint
      rules = exposure.rules || []
      guard = exposure.guard
      return nil if rules.empty? || guard.roles.any? || guard.leaves.any? { |leaf| leaf.kind == :owner }

      signed_in = signed_in_only?
      "if this is meant for #{signed_in ? "every signed-in user" : "everyone"}, declare it in the map block: " \
        "#{public_declarations(rules, signed_in).join(" / ")}"
    end

    # The guard checks sign-in and the witness is signed in.
    def signed_in_only? = !anonymous? && exposure.guard.leaves.any? { |leaf| leaf.kind == :logged_in }

    def public_declarations(rules, signed_in)
      rules.map do |key|
        policy, rule = key.split("#", 2)
        "public_action \"#{policy}\", :#{rule}#{", audience: :signed_in" if signed_in}"
      end
    end

    def who
      return "an anonymous visitor" if anonymous?

      base = "a signed-in #{@mapping.principal_name} (#{user_label(principal)})"
      current = current_tenant
      return "#{base} holding #{held(roles)}" unless current

      own = " (their own)" if current.user == principal
      outside = " and #{held(roles)} outside any tenant" if roles.any?
      "#{base} holding #{held(current.roles)} in the current tenant #{tenant_label(current)}#{own}#{outside}"
    end

    # Every role the witness holds: outside tenants, in the current tenant
    # and in the record's.
    def held_anywhere = roles + [current_tenant, record_tenant].compact.flat_map(&:roles)

    def held(names) = names.empty? ? "no roles" : "roles #{names.join(", ")}"

    def verb = exposure.op == :read ? "read" : "update"

    def what
      field = exposure.field
      "#{"the #{field} of " if field}#{record_label}#{where}#{flag_list}"
    end

    # ", with project_public and without public_builds"
    def flag_list
      return "" if flags.empty?

      on, off = flags.keys.partition { |name| flags.fetch(name) }
      parts = []
      parts << "with #{on.join(", ")}" if on.any?
      parts << "without #{off.join(", ")}" if off.any?
      ", #{parts.join(" and ")}"
    end

    def record_label
      if @resource.kind == :profile
        own_record? ? "their own profile" : "the #{@resource.name} profile of #{user_label(owner)}"
      elsif @resource.owned?
        own_record? ? "#{a_resource} they own" : "#{a_resource} owned by #{user_label(owner)}"
      else
        "#{a_resource} (#{Naming.atom(record)})"
      end
    end

    # "a Link", "an OfferCode" (by spelling: a leading U reads as "you").
    def a_resource
      name = @resource.name
      "#{name.match?(/\A[AEIO]/i) ? "an" : "a"} #{name}"
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
