# typed: strict
# frozen_string_literal: true

module Hallmark
  # Turns recorded stamps into exposures, until the phase 2 extractor can
  # read guards from policy code (docs/adr/0002).
  #
  # A rule's inferred guard is the OR of its allow-stamps, each the
  # conjunction of the facts that held. Only true facts become literals: the
  # catalog allows more as a principal gains roles, ownership or membership,
  # so dropping the false ones changes no verdict and keeps guards readable.
  # A hand-written guard (`rule ..., guard:` in the map block) replaces the
  # inferred one.
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
    Unit = Struct.new(:policy, :rule, :resource, :op, :stamps, :guard, :basis, keyword_init: true) do
      def key = "#{policy}##{rule}"
      def allows = stamps.select(&:allow?)
      def denies = stamps.reject(&:allow?)
      def entry_points = stamps.select(&:enforced).filter_map(&:entry_point).uniq
    end

    # A redirect the browser follows with a GET: the response served no data.
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    SAFE_VERBS = %w[GET HEAD].freeze

    attr_reader :units, :exposures, :coverage, :unchecked

    def initialize(mapping, stamp_set)
      @mapping = mapping
      @stamps = stamp_set.stamps
      @coverage = Coverage.new(mapping, @stamps)
      @units = build_units
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

    def unit_for(policy, rule, resource, stamps)
      op = @mapping.op_for(policy, rule)
      unless op
        @coverage.without_op << "#{policy}##{rule}"
        return nil
      end

      unit = Unit.new(policy: policy, rule: rule, resource: resource, op: op, stamps: stamps)
      assign_guard(unit)
      @coverage.observe(unit)
      unit
    end

    def assign_guard(unit)
      allows = unit.allows
      if (written = @mapping.rules[unit.key]&.guard)
        unit.guard = written
        unit.basis = "hand-written for #{unit.key}"
      elsif allows.any?
        unit.guard = inferred_guard(allows, @mapping.fetch(unit.resource))
        unit.basis = "inferred from #{allows.size} allow-stamp#{"s" unless allows.size == 1} of #{unit.key}"
      end
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

    # Role literals only: holding a role in a tenant implies membership there.
    def tenant_literals(stamp, resource, out)
      current = Array(stamp.current_roles).sort
      if resource.tenanted? && stamp.in_current_tenant
        out << in_current_tenant
        current.each { |name| out << role(name, tenant: :current) }
        return
      end

      Array(stamp.record_roles).sort.each { |name| out << role(name, tenant: :record) } if resource.tenanted?
      current.each { |name| out << role(name, tenant: :current) }
    end

    def build_exposures
      links = Hash.new { |hash, key| hash[key] = [] }
      @units.each do |unit|
        unit.entry_points.each { |entry_point| links[entry_point] << unit }
        @coverage.unreached << unit.key if unit.entry_points.empty?
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
