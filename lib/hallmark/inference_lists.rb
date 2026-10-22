# typed: strict
# frozen_string_literal: true

module Hallmark
  # List scopes (phase 3 step 7): units from list stamps and from the
  # scopes the extractor read, and one list exposure per entry point and
  # resource that listed records.
  class Inference
    private

    def list_units
      stamped = list_stamp_units
      seen = stamped.map { |unit| [unit.key, unit.resource] }
      code = (@extractor&.lists || []).filter_map do |extracted|
        resource = extracted.resource
        next if resource.nil? || seen.include?([extracted.key, resource])

        list_unit(extracted.policy, extracted.rule, resource, extracted: extracted)
      end
      stamped + code
    end

    # Record stamps feed the guard; calls (class-level) only name entry points.
    def list_stamp_units
      mapped = @list_stamps.select { |stamp| @mapping.resources.key?(stamp.resource.to_s) }
      groups = mapped.group_by { |stamp| [stamp.policy.to_s, stamp.rule.to_s, stamp.resource.to_s] }
      groups.sort.map do |(policy, rule, resource), stamps|
        calls, records = stamps.partition(&:class_level)
        list_unit(policy, rule, resource, stamps: with_outside_tenants(records, @mapping.fetch(resource)),
                                          calls: calls, extracted: @extractor&.list(policy, rule, resource))
      end
    end

    def list_unit(policy, rule, resource, extracted:, stamps: [], calls: [])
      unit = Unit.new(policy: policy, rule: rule, resource: resource, op: :read, stamps: stamps, calls: calls,
                      extracted: extracted, kind: :list)
      assign_guard(unit)
      @coverage.observe(unit)
      unit
    end

    # One list exposure per entry point and resource: the OR of the guards
    # of the scopes it listed (the list shows their union).
    def list_exposures(units)
      links = Hash.new { |hash, key| hash[key] = [] }
      units.each do |unit|
        @coverage.code_only << unit.key if unit.stamps.empty? && (unit.calls || []).empty?
        unit.entry_points.each { |entry_point| links[[entry_point, unit.resource]] << unit }
      end
      links.keys.sort.filter_map do |entry_point, resource|
        list_exposure(entry_point, resource, links.fetch([entry_point, resource]))
      end
    end

    def list_exposure(entry_point, resource, units)
      guarded = units.select(&:guard)
      return nil if guarded.empty?

      exposure = Exposure.new(action: entry_point, op: :read, resource: resource, guard: union(guarded),
                              basis: guarded.map(&:basis).join("; "), kind: :list, rules: guarded.map(&:key),
                              locations: list_locations(guarded))
      ask_tenants(exposure)
      exposure
    end

    def union(units)
      units.filter_map(&:guard).reduce { |left, right| Guard.disjoin(left, right) } || Guard.new(:never)
    end

    # Where the scopes are written, for SARIF.
    def list_locations(units) = units.filter_map { |unit| unit.extracted&.location }.uniq

    # A list that may show another tenant's records, on a resource not
    # mapped `lists: :current_tenant`: a question under coverage, not a
    # failure, since a dashboard across tenants can be intended (M5).
    def ask_tenants(exposure)
      return unless ListScope.across_tenants?(@mapping, exposure.resource, exposure.guard)

      @coverage.cross_tenant_lists << "#{exposure.action} (#{exposure.resource})"
    end
  end
end
