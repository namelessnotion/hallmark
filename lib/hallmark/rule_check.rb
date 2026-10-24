# typed: strict
# frozen_string_literal: true

module Hallmark
  # Checks a policy's rules one at a time against the catalog, for the RSpec
  # matchers. Exposures are keyed by entry point (docs/adr/0001), but a rule
  # stays a unit of its own: here each rule becomes one check of its guard
  # alone, named after the rule ("LinkPolicy#update?").
  #
  # A rule's guard is the mapping's hand-written one (`rule ..., guard:`),
  # else the lower bound of the guard read from its code (when an extractor
  # is given; docs/adr/0003) OR the one inferred from its allow-stamps
  # (docs/adr/0002). A rule with none has nothing to check, so its verdict
  # is :not_observed: a coverage gap, never a finding and never a pass.
  #
  # A rule's drift (`Drift`: stamps its code, as the extractor read it,
  # contradicts) rides on its result whatever the verdict, since the guard
  # checked was built on a reading the stamps disagree with; so does its
  # stale access (`StaleAccess`: an allow after a revocation that nothing
  # else explains).
  #
  #   check = Hallmark::RuleCheck.new(mapping, Hallmark::StampSet.load("tmp/hallmark"))
  #   check.check("LinkPolicy", ["update?"]).each { |result| puts result.lines }
  class RuleCheck
    # One rule's outcome on one kind of record. `verdict` is :counterexample
    # (with `finding`), :none (no counterexample within scope), :unknown (the
    # solver gave no verdict; `reason` says why) or :not_observed (nothing to
    # check; `reason` says why). `exposure` is nil only when not observed.
    # `drift` is the rule's drift on that kind of record (nil for none), and
    # `stale` its stale access there.
    #
    # `question` is, for a list scope, what coverage would ask about it
    # (`ListScope.question`): it may show another tenant's records.
    Result = Struct.new(:policy, :rule, :exposure, :verdict, :finding, :reason, :drift, :question, :stale,
                        keyword_init: true) do
      def key = "#{policy}##{rule}"
      def counterexample? = verdict == :counterexample
      def none? = verdict == :none
      def drifts = drift || []
      def drift? = drifts.any?
      def stales = stale || []
      def stale? = stales.any?

      # The rule as `hallmark check` would print it: its verdict, then its
      # drift and stale access.
      def lines
        asked = question
        verdict_lines + (asked ? ["      #{asked}"] : []) + drifts.flat_map { |item| Report.drift_lines(item) } +
          stales.flat_map { |item| Report.stale_lines(item) }
      end

      private

      def verdict_lines
        found = finding
        checked = exposure
        return Report.finding_lines(found) if found
        return ["--    #{key}: not observed, #{reason}"] unless checked
        return [Report.unknown_line(checked, reason.to_s)] if verdict == :unknown

        [Report.ok_line(checked)]
      end
    end

    attr_reader :mapping, :stamps

    def initialize(mapping, stamps = StampSet.new, extractor: nil)
      @mapping = mapping.validate!
      @stamps = stamps
      inference = Inference.new(mapping, stamps, extractor: extractor)
      @units = inference.units
      @drift = inference.drift
      @stale = inference.stale_access
      @ops = inference.ops
    end

    # The rules known for a policy, sorted: those stamped against a record of
    # a mapped resource, those read from its code (with an extractor), and
    # those with a hand-written guard.
    def rules(policy)
      name = Naming.class_name(policy)
      stamped = @units.select { |unit| unit.policy == name }.map(&:rule)
      written = @mapping.rules.values.select { |rule| rule.policy == name && rule.guard }.map(&:name)
      (stamped + written).uniq.sort
    end

    # Checks the named rules of a policy (every known rule when `names` is
    # nil) in one solver run, one check per rule and resource.
    def check(policy, names = nil, solver: Hallmark.solver)
      name = Naming.class_name(policy)
      results = (names&.map(&:to_s) || rules(name)).flat_map { |rule| pending(name, rule) }
      checked = results.select(&:exposure)
      record(analysis(name, checked).run(solver: solver), checked) if checked.any?
      results
    end

    private

    def analysis(name, checked)
      analysis = Analysis.new("#{name} rules", mapping: @mapping)
      checked.each do |result|
        next unless (exposure = result.exposure)

        result.exposure = analysis.add_exposure(action: exposure.action, op: exposure.op, resource: exposure.resource,
                                                guard: exposure.guard, basis: exposure.basis, rules: exposure.rules,
                                                field: exposure.field, locations: exposure.locations,
                                                kind: exposure.kind)
      end
      analysis.validate!
    end

    # A rule's results before the solver runs: one per resource it was
    # stamped on, else one for its hand-written guard, else not observed.
    def pending(policy, rule)
      key = "#{policy}##{rule}"
      units = @units.select { |unit| unit.key == key }
      return units.map { |unit| from_unit(unit) } if units.any?

      written = @mapping.rules[key]
      guard = written&.guard
      return [from_rule(written, guard)] if written && guard

      [Result.new(policy: policy, rule: rule, verdict: :not_observed, reason: unstamped(key))]
    end

    def from_unit(unit)
      result = Result.new(policy: unit.policy, rule: unit.rule, drift: of_unit(@drift, unit),
                          stale: of_unit(@stale, unit))
      guard = unit.guard
      unless guard
        result.verdict = :not_observed
        result.reason = unguarded(unit)
        return result
      end

      # The check name carries the resource, so a rule stamped on two kinds of
      # record becomes two checks without renaming the rule.
      exposure = Exposure.new(action: unit.key, op: unit.op, resource: unit.resource, guard: guard,
                              basis: unit.basis, rules: [unit.key], kind: unit.kind,
                              locations: [unit.extracted&.location].compact)
      result.exposure = exposure
      if unit.list? && ListScope.across_tenants?(@mapping, unit.resource, guard)
        result.question = ListScope.question(unit.resource)
      end
      result
    end

    # The drift or stale access of one unit: its rule on its resource.
    def of_unit(items, unit) = items.select { |item| item.rule == unit.key && item.resource == unit.resource }

    def from_rule(rule, guard)
      resource = rule.resource || convention(rule)
      op = @ops.fetch(rule.policy, rule.name)
      unless op
        raise ConfigurationError, "rule #{rule.key} has no op; declare `rule \"#{rule.policy}\", " \
                                  ":#{rule.name}, op: :read` (or :write)"
      end

      Result.new(policy: rule.policy, rule: rule.name,
                 exposure: Exposure.new(action: rule.key, op: op, resource: resource, guard: guard,
                                        basis: "hand-written for #{rule.key}", rules: [rule.key]))
    end

    def unguarded(unit)
      if unit.list?
        return "no listed record was recorded and the mapping declares no guard for it" unless unit.extracted

        return "no listed record was recorded, and its scope keeps records only through calls Hallmark could " \
               "not read; declare a `term` for them"
      end
      denies = unit.denies.size
      stamped = "no allow-stamp was recorded (#{denies} deny-stamp#{"s" unless denies == 1})"
      return "#{stamped} and the mapping declares no guard for it" unless unit.extracted

      "#{stamped}, and its code allows only through calls Hallmark could not read; declare a `term` for them"
    end

    # LinkPolicy checks Link, when Link is mapped.
    def convention(rule)
      name = rule.policy.delete_suffix("Policy")
      return name if name != rule.policy && @mapping.resources.key?(name)

      raise ConfigurationError, "rule #{rule.key} has a hand-written guard but no stamp shows which resource " \
                                "it checks; add `resource:` to its `rule` declaration"
    end

    # Why a rule with no unit has nothing to check.
    def unstamped(key)
      stamps = @stamps.stamps.select { |stamp| stamp.rule_key == key }
      return "no stamp of it was recorded and the mapping declares no guard for it" if stamps.empty?
      return "checked only against a class or a name, not a record (not modeled)" if stamps.all?(&:class_level)

      unmapped = stamps.map { |stamp| stamp.resource.to_s }.reject { |name| @mapping.resources.key?(name) }.uniq
      return "stamped on unmapped resources (#{unmapped.join(", ")}); map them with `resource`" if unmapped.any?

      "it has no op; declare `rule POLICY, NAME, op:` in the map block"
    end

    def record(report, checked)
      by_check = checked.to_h { |result| [result.exposure&.check_name, result] }
      report.findings.each do |finding|
        result = by_check.fetch(finding.exposure.check_name)
        result.verdict = :counterexample
        result.finding = finding
      end
      report.unknown.each do |item|
        result = by_check.fetch(item.exposure.check_name)
        result.verdict = :unknown
        result.reason = item.reason
      end
      report.verified.each { |exposure| by_check.fetch(exposure.check_name).verdict = :none }
    end
  end
end
