# typed: strict
# frozen_string_literal: true

module Hallmark
  # An allow-stamp made after the user lost a role (`Stamp#after_revocation`,
  # from the test-mode revocations collector) that nothing else explains:
  # threat 9, stale access after revocation (phase 3 step 9).
  #
  # Inference sets such stamps aside, so they feed no guard, and judges
  # each against what its rule allows without it: the hand-written guard,
  # else the extracted lower bound OR the guard inferred from the other
  # allow-stamps (a list record against its list's guard). True means other
  # access explains it (a public record, another role, ownership), and it
  # is dropped and counted under coverage. False is stale access, which
  # fails the check. Unknown, or a rule with no guard at all, is listed
  # under coverage as not judged, never failed, as an unknown is never
  # drift. Stamps with the same rule, resource, revoked roles and facts
  # collapse into one, listing where each was seen.
  StaleAccess = Struct.new(:rule, :resource, :revoked, :facts, :tenant, :location, :seen, keyword_init: true) do
    # What makes two the same, across runs.
    def key = "#{rule}|#{resource}|#{revoked.join(",")}|#{facts}"

    # The stale access among `stamps` (the set-aside ones), in unit order;
    # what is explained or cannot be judged goes to `coverage`.
    def self.judge(mapping, stamps, units, coverage)
      judged = stamps.filter_map do |stamp|
        unit = unit_for(stamp, units)
        verdict = verdict(mapping, stamp, unit)
        next [stamp, unit] if unit && verdict == false

        note(coverage, stamp, verdict)
        nil
      end
      groups = judged.group_by do |stamp, unit|
        [unit.key, unit.resource, Array(stamp.after_revocation), facts_of(mapping, stamp)]
      end
      groups.map { |(rule, resource, revoked, facts), group| build(rule, resource, revoked, facts, group) }
    end

    def self.build(rule, resource, revoked, facts, group)
      stamps = group.map(&:first)
      first, unit = group.fetch(0)
      new(rule: rule, resource: resource, revoked: revoked, facts: facts, tenant: tenant_of(first, revoked),
          location: unit.extracted&.location,
          seen: stamps.map { |stamp| stamp.entry_point || "outside a request" }.uniq.sort)
    end

    # The unit the stamp would have joined: its rule on its resource, a
    # list's for a list record.
    def self.unit_for(stamp, units)
      units.find do |unit|
        unit.policy == stamp.policy.to_s && unit.rule == stamp.rule.to_s && unit.resource == stamp.resource.to_s &&
          unit.list? == (stamp.list == true)
      end
    end

    # True (explained), false (stale) or nil (not judged).
    def self.verdict(mapping, stamp, unit)
      guard = unit&.guard
      return nil unless guard && mapping.resources.key?(stamp.resource.to_s)

      guard.evaluate(StampFacts.new(mapping, mapping.fetch(stamp.resource.to_s), stamp))
    end

    def self.note(coverage, stamp, verdict)
      line = "#{stamp.rule_key} (#{stamp.resource}) at #{stamp.entry_point || "outside a request"}, after losing " \
             "#{Array(stamp.after_revocation).join(", ")}"
      list = verdict ? coverage.stale_explained : coverage.stale_unjudged
      list << line unless list.include?(line)
    end

    def self.facts_of(mapping, stamp)
      resource = mapping.resources[stamp.resource.to_s]
      resource ? StampFacts.new(mapping, resource, stamp).to_s : ""
    end

    # Where the roles were lost, as far as the stamp tells: the record's
    # tenant, the current tenant, or either.
    def self.tenant_of(stamp, revoked)
      return "the current tenant" if stamp.in_current_tenant || stamp.record_roles.nil?
      return "the record's tenant" if stamp.current_roles.nil?

      places = { "the record's tenant" => stamp.record_roles, "the current tenant" => stamp.current_roles }
      lacking = places.select { |_, roles| revoked.any? { |name| !Array(roles).include?(name) } }.keys
      lacking.size == 1 ? lacking.fetch(0) : "the record's tenant or the current tenant"
    end
  end
end
