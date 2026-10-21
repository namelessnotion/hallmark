# typed: strict
# frozen_string_literal: true

module Hallmark
  # Turns recorded stamps, and the guards the extractor read from policy
  # code, into exposures (docs/adr/0002 and 0003).
  #
  # A rule's inferred guard is the OR of its allow-stamps, each the
  # conjunction of the facts that held (`StampFacts#literals`, true facts
  # only).
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
  # fails the report unless `UncheckedRequests` excuses it.
  #
  # Stamps the extracted guard contradicts are drift (`Drift`), which also
  # fails the report.
  #
  # An exposure also carries what its controller requires: the current
  # tenant when the record is loaded through it, and the lower bound of the
  # checks the controller makes in its own code (`Extractor::Controllers`).
  #
  # A rule's op comes from `Ops`: the mapping, the rule's name, then the
  # routes that reach it (those recorded, else those read from
  # `config/routes.rb`).
  #
  # When the app has `app/graphql`, the reachability checks of its schema
  # (`GraphqlModel#checks`) follow the entry points' exposures.
  class Inference
    include Guard::DSL

    # One rule as checked against one kind of record.
    Unit = Struct.new(:policy, :rule, :resource, :op, :stamps, :guard, :basis, :extracted, keyword_init: true) do
      def key = "#{policy}##{rule}"
      def allows = stamps.select(&:allow?)
      def denies = stamps.reject(&:allow?)
      def entry_points = stamps.select(&:enforced).filter_map(&:entry_point).uniq
    end

    attr_reader :units, :exposures, :coverage, :unchecked, :drift, :extractor, :ops, :stamp_set, :graphql

    def initialize(mapping, stamp_set, extractor: nil)
      @mapping = mapping
      @stamp_set = stamp_set
      @stamps = stamp_set.stamps
      @routes = stamp_set.routes
      @reached = (@stamps.filter_map(&:entry_point) + stamp_set.unchecked.map(&:entry_point)).uniq
      @extractor = extractor
      @ops = Ops.new(mapping, stamps: @stamps, routes: @routes.empty? ? extractor&.routes || [] : @routes,
                              controllers: extractor&.controllers)
      @coverage = Coverage.new(mapping, @stamps, mismatches: stamp_set.mismatches)
      stamped = build_units
      @units = (stamped + code_units(stamped.map(&:key))).sort_by { |unit| [unit.policy, unit.rule, unit.resource] }
      @exposures = build_exposures
      @drift = Drift.find(mapping, @units)
      @unchecked = UncheckedRequests.new(mapping, @stamps, extractor, @coverage).failing(stamp_set.unchecked)
    end

    private

    # The checks of the app's GraphQL model, which this sets (`graphql`).
    def graphql_checks
      @graphql = @extractor&.graphql&.model
      @graphql&.checks || []
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
      op = @ops.fetch(policy, rule)
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
        next unless (op = @ops.fetch(extracted.policy, extracted.rule))

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
      unit.basis = [*parts.map(&:last), @ops.basis(unit.policy, unit.rule)].compact.join("; ")
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
      resource = @mapping.fetch(unit.resource)
      allows = unit.allows.select { |stamp| readable?(stamp, resource) }
      @coverage.stale << unit.key if allows.size < unit.allows.size
      return nil if allows.empty?

      [inferred_guard(allows, resource),
       "inferred from #{allows.size} allow-stamp#{"s" unless allows.size == 1} of #{unit.key}"]
    end

    # A stamp recorded before its resource's facts were mapped (no owner
    # fact for a resource now mapped with an owner, no publicity fact for
    # one now public sometimes) says nothing about those facts, so it is
    # not read into a guard: read as is, its allow would drop ownership.
    def readable?(stamp, resource)
      return true if stamp.class_level
      return false if resource.owned? && stamp.owner.nil?

      !(resource.public? && !resource.always_public? && stamp.public_record.nil?)
    end

    # Printed as the literals every allow-stamp shares, AND the OR of the
    # rest, sorted so that the guard does not depend on test order.
    def inferred_guard(allows, resource)
      sets = minimal(allows.map { |stamp| StampFacts.new(@mapping, resource, stamp).literals }.uniq)
      common = sets.reduce(:&) || []
      alternatives = sets.map { |set| set - common }.reject(&:empty?).map { |set| conjunction(set) }
      conjunction([*common, *alternatives.sort_by(&:to_s).reduce(:|)])
    end

    def conjunction(guards) = guards.reduce(:&) || none

    # A conjunction whose literals include another's adds nothing to the OR.
    def minimal(sets)
      sets.reject { |set| sets.any? { |other| other != set && (other - set).empty? } }
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
      exposures = links.keys.sort.flat_map { |entry_point| exposures_of(entry_point, links.fetch(entry_point)) }
      exposures + route_exposures + graphql_checks
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

      guard = guards.compact.reduce(:&)
      basis = units.map(&:basis).join("; ")
      if (scoped = scoped_load(entry_point, resource))
        guard = in_current_tenant & guard
        basis += "; record loaded through #{@mapping.current_tenant_controller} (#{scoped})"
      end
      guard, basis = controller_checks(entry_point, resource, guard, basis)
      return nil unless guard && basis

      Exposure.new(action: entry_point, op: op, resource: resource, guard: guard, basis: basis,
                   locations: locations_for(entry_point, resource, units), rules: units.map(&:key))
    end

    # The checks the entry point's controller makes in its own code
    # (`e404 unless product.user == current_seller`), ANDed in by their
    # lower bound: the request goes on only where they hold (docs/adr/0003).
    # Nil when a check leaves nothing certain, every way through it
    # depending on calls Hallmark could not read: the entry point is listed
    # under coverage, as a rule that never allows is.
    def controller_checks(entry_point, resource, guard, basis)
      checks = controllers&.checks(entry_point, resource) || []
      return [guard, basis] if checks.empty?

      checked = checks.reduce(guard) { |all, check| Guard.conjoin(all, check.guard.lower) }
      @coverage.observe_checks(entry_point, checks.map(&:guard), certain: checked.kind != :never)
      [checked, "#{basis}; checked in the controller (#{checks.map(&:location).join(", ")})"] if checked.kind != :never
    end

    # Where an entry point authorizes a record it loaded through the current
    # tenant, read from the controller (`current_seller.products.find(...)`):
    # the record is then in the current tenant whatever its rules allow.
    def scoped_load(entry_point, resource)
      return nil unless @mapping.fetch(resource).tenanted?

      controllers&.fetch(entry_point)&.then { |read| read.location if read.scoped? }
    end

    def controllers = @extractor&.controllers
  end
end
