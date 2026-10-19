# typed: strict
# frozen_string_literal: true

module Hallmark
  # Turns recorded stamps, and the guards the extractor read from policy
  # code, into exposures (docs/adr/0002 and 0003).
  #
  # A rule's inferred guard is the OR of its allow-stamps, each the
  # conjunction of the facts that held. Only true facts become literals: the
  # catalog allows more as a principal gains roles, ownership or membership,
  # so dropping the false ones changes no verdict and keeps guards readable.
  # With an extractor, a rule's guard is the lower bound of its extracted
  # guard OR the inferred one: both are access the app certainly grants.
  # Rules the code defines that no stamp shows become units too, with no
  # entry point. A hand-written guard (`rule ..., guard:` in the map block)
  # replaces both.
  #
  # An exposure is an entry point, keyed as in docs/adr/0001: its guard is the
  # AND of the rules it enforced (`authorize`, `authorize!`) on one kind of
  # record with one op. Queries such as `allowed_to?` feed rule guards but do
  # not tie a rule to an entry point.
  #
  # An entry point that finished without an authorization call (threat 10)
  # fails the report, unless the mapping allows it (`allow_unchecked`) or the
  # request was a GET or HEAD the action answered with a redirect while some
  # other request to the same entry point reached a rule: a branch such as
  # `return redirect_to root_path unless feature_enabled?` before
  # `authorize`. Those are listed under coverage instead.
  class Inference
    include Guard::DSL

    # One rule as checked against one kind of record.
    Unit = Struct.new(:policy, :rule, :resource, :op, :stamps, :guard, :basis, :extracted, keyword_init: true) do
      def key = "#{policy}##{rule}"
      def allows = stamps.select(&:allow?)
      def denies = stamps.reject(&:allow?)
      def entry_points = stamps.select(&:enforced).filter_map(&:entry_point).uniq
    end

    # A redirect the browser follows with a GET: the response served no data.
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    SAFE_VERBS = %w[GET HEAD].freeze

    attr_reader :units, :exposures, :coverage, :unchecked

    def initialize(mapping, stamp_set, extractor: nil)
      @mapping = mapping
      @stamps = stamp_set.stamps
      @extractor = extractor
      @coverage = Coverage.new(mapping, @stamps)
      stamped = build_units
      @units = (stamped + code_units(stamped.map(&:key))).sort_by { |unit| [unit.policy, unit.rule, unit.resource] }
      @exposures = build_exposures
      @unchecked = classify_unchecked(stamp_set.unchecked)
    end

    private

    # The unchecked entry points that fail the report, sorted; excused
    # redirects go to `coverage.redirected`. An entry point fails when any
    # of its unchecked requests is not excused.
    def classify_unchecked(events)
      events = events.reject { |event| @mapping.unchecked_allowed.include?(event.entry_point) }
      excused, failing = events.partition { |event| redirect_before_check?(event) }
      failed = failing.map(&:entry_point).uniq.sort
      @coverage.redirected.concat((excused.map(&:entry_point).uniq - failed).sort)
      failed
    end

    # A GET or HEAD answered with a redirect, at an entry point some other
    # request took to a rule (any stamp, allowed or denied). Writes that
    # redirect, 304s and empty 2xx still fail, and so does an entry point
    # that never reached a rule (a signed-URL redirect may be an IDOR).
    def redirect_before_check?(event)
      SAFE_VERBS.include?(event.verb) && REDIRECTS.include?(event.status) &&
        @stamps.any? { |stamp| stamp.entry_point == event.entry_point }
    end

    def build_units
      record_level = @stamps.reject(&:class_level)
      mapped, unmapped = record_level.partition { |stamp| @mapping.resources.key?(stamp.resource.to_s) }
      @coverage.class_level.concat(@stamps.select(&:class_level).map(&:rule_key).uniq.sort)
      @coverage.unmapped.concat(unmapped.map { |stamp| stamp.resource.to_s }.uniq.sort)
      groups = mapped.group_by { |stamp| [stamp.policy.to_s, stamp.rule.to_s, stamp.resource.to_s] }
      groups.sort.filter_map { |(policy, rule, resource), stamps| unit_for(policy, rule, resource, stamps) }
    end

    # Stamps written before `outside_tenants` existed mark a record with no
    # tenant only by leaving `record_roles` unset (a tenanted record always
    # has a list, empty for a non-member).
    def with_outside_tenants(stamps, resource)
      return stamps unless resource.tenant_optional?

      stamps.map do |stamp|
        next stamp unless stamp.outside_tenants.nil? && stamp.record_roles.nil?

        Stamp.new(**stamp.to_h, outside_tenants: true)
      end
    end

    def unit_for(policy, rule, resource, stamps)
      op = @mapping.op_for(policy, rule)
      unless op
        @coverage.without_op << "#{policy}##{rule}"
        return nil
      end

      unit = Unit.new(policy: policy, rule: rule, resource: resource, op: op,
                      stamps: with_outside_tenants(stamps, @mapping.fetch(resource)),
                      extracted: @extractor&.fetch(policy, rule))
      assign_guard(unit)
      @coverage.observe(unit)
      unit
    end

    # Rules the extractor read that have no unit from stamps, on the
    # resource the mapping or the policy's name gives them.
    def code_units(stamped)
      extractor = @extractor
      return [] unless extractor

      extractor.rules.filter_map do |extracted|
        resource = extracted.resource
        next if resource.nil? || stamped.include?(extracted.key)
        next unless (op = @mapping.op_for(extracted.policy, extracted.rule))

        unit = Unit.new(policy: extracted.policy, rule: extracted.rule, resource: resource, op: op, stamps: [],
                        extracted: extracted)
        assign_guard(unit)
        @coverage.observe(unit)
        unit
      end
    end

    def assign_guard(unit)
      if (written = @mapping.rules[unit.key]&.guard)
        unit.guard = written
        unit.basis = "hand-written for #{unit.key}"
        return
      end

      parts = [extracted_part(unit), inferred_part(unit)].compact
      return if parts.empty?

      unit.guard = parts.map(&:first).reduce { |left, right| Guard.disjoin(left, right) }
      unit.basis = parts.map(&:last).join("; ")
    end

    # The extracted guard's lower bound, unless it allows nothing for sure.
    def extracted_part(unit)
      extracted = unit.extracted
      return nil unless extracted

      lower = extracted.lower
      return nil if lower.kind == :never

      bounded = extracted.exact? ? "" : ", lower bound"
      [lower, "extracted from #{unit.key} (#{extracted.location}#{bounded})"]
    end

    def inferred_part(unit)
      allows = unit.allows
      return nil if allows.empty?

      [inferred_guard(allows, @mapping.fetch(unit.resource)),
       "inferred from #{allows.size} allow-stamp#{"s" unless allows.size == 1} of #{unit.key}"]
    end

    # Printed as the literals every allow-stamp shares, AND the OR of the
    # rest, sorted so that the guard does not depend on test order.
    def inferred_guard(allows, resource)
      sets = minimal(allows.map { |stamp| literals(stamp, resource) }.uniq)
      common = sets.reduce(:&) || []
      alternatives = sets.map { |set| set - common }.reject(&:empty?).map { |set| conjunction(set) }
      conjunction([*common, *alternatives.sort_by(&:to_s).reduce(:|)])
    end

    def conjunction(guards) = guards.reduce(:&) || none

    # A conjunction whose literals include another's adds nothing to the OR.
    def minimal(sets)
      sets.reject { |set| sets.any? { |other| other != set && (other - set).empty? } }
    end

    def literals(stamp, resource)
      out = record_literals(stamp, resource)
      out << permitted if stamp.permitted && resource.permits?
      roles = Array(stamp.roles)
      if @mapping.tenancy
        tenant_literals(stamp, resource, out)
        # Outside tenants users hold only platform roles (docs/PLAN.md).
        roles &= @mapping.platform_roles
      end
      roles.sort.each { |name| out << role(name) }
      out
    end

    def record_literals(stamp, resource)
      out = []
      out << logged_in if stamp.logged_in
      out << public_record if stamp.public_record && resource.public? && !resource.always_public?
      out << owner if stamp.owner && resource.owned?
      out
    end

    # Where the record lives, then roles; no membership literal, since
    # holding a role in a tenant implies membership there. A record with no
    # tenant gets `outside_tenants`, so that an owner's allow on a personal
    # record does not stand for records in a tenant.
    def tenant_literals(stamp, resource, out)
      out.concat(record_tenant_literals(stamp, resource)) if resource.tenanted?
      Array(stamp.current_roles).sort.each { |name| out << role(name, tenant: :current) }
    end

    # Where the record lives: outside tenants, in the current tenant, or in
    # another, with the roles held there.
    def record_tenant_literals(stamp, resource)
      return [outside_tenants] if resource.tenant_optional? && stamp.outside_tenants
      return [in_current_tenant] if stamp.in_current_tenant

      Array(stamp.record_roles).sort.map { |name| role(name, tenant: :record) }
    end

    def build_exposures
      links = Hash.new { |hash, key| hash[key] = [] }
      @units.each do |unit|
        unit.entry_points.each { |entry_point| links[entry_point] << unit }
        if unit.stamps.empty?
          @coverage.code_only << unit.key
        elsif unit.entry_points.empty?
          @coverage.unreached << unit.key
        end
      end
      links.keys.sort.flat_map { |entry_point| exposures_of(entry_point, links.fetch(entry_point)) }
    end

    def exposures_of(entry_point, units)
      groups = units.group_by { |unit| [unit.op, unit.resource] }
      groups.sort_by { |(op, resource), _| [op, resource] }.filter_map do |(op, resource), group|
        exposure_for(entry_point, op, resource, group.sort_by(&:key))
      end
    end

    # Nil when a rule never allowed: the entry point never got past it, so
    # there is nothing to check (the rule is listed under coverage).
    def exposure_for(entry_point, op, resource, units)
      guards = units.map(&:guard)
      return nil if guards.include?(nil)

      Exposure.new(
        action: entry_point, op: op, resource: resource,
        guard: guards.compact.reduce(:&), basis: units.map(&:basis).join("; ")
      )
    end
  end
end
