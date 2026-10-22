# typed: strict
# frozen_string_literal: true

module Hallmark
  # What a counterexample's witness says about each guard leaf, read from
  # the decoded finding rather than by asking the solver again, so a
  # finding can tell which part of its check the witness broke: a field's
  # policy or a restriction. Leaves the witness cannot answer (public
  # records, permits, roles in any tenant, the current tenant when the
  # finding did not read it) are unknown, nil, which `Guard#evaluate` reads
  # as such.
  class WitnessFacts
    def initialize(finding, platform_roles)
      @finding = finding
      @platform_roles = platform_roles
    end

    def [](leaf)
      finding = @finding
      case leaf.kind
      when :logged_in then !finding.anonymous?
      when :owner then finding.own_record?
      when :admin then finding.roles.include?("Admin")
      when :role then role_held?(leaf.operands[0].to_s, leaf.operands[1])
      when :member then (finding.record_tenant&.roles || []).any?
      when :in_current_tenant then in_current_tenant
      when :outside_tenants then finding.record_tenant.nil?
      when :flag then finding.flags[leaf.operands[0].to_s]
      end
    end

    # Whether `guard` holds for the witness: true, false or nil, unknown.
    def evaluate(guard) = guard.evaluate(self)

    # The witness holds the denial's role where it counts (anywhere for a
    # platform role, else in the record's tenant, or outside tenants for a
    # record with none), and the denial's condition is not false for the
    # witness record.
    def denied?(denial)
      finding = @finding
      target = finding.record_tenant
      held = @platform_roles.include?(denial.role) || target.nil? ? finding.roles : target.roles
      return false unless held.include?(denial.role)

      condition = denial.condition
      condition.nil? || evaluate(condition) != false
    end

    private

    def role_held?(name, tenant)
      finding = @finding
      case tenant
      when nil then finding.roles.include?(name)
      when :record then (finding.record_tenant&.roles || []).include?(name)
      when :current then finding.current_tenant&.roles&.include?(name)
      end
    end

    def in_current_tenant
      current = @finding.current_tenant
      current && @finding.record_tenant&.tenant == current.tenant
    end
  end
end
