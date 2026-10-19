# typed: strict
# frozen_string_literal: true

module Hallmark
  # A decision the stamps recorded that the rule's code, as the extractor
  # read it, contradicts (docs/adr/0003): an allow where the extracted
  # guard's upper bound is false, so no outcome of the unread calls could
  # have allowed, or a deny (a rule that raised included) where its lower
  # bound is true, so the code allows whatever those calls return. Either
  # way the extractor or a mapped term is wrong, and every check built on
  # that guard is suspect, so drift fails `hallmark check`.
  #
  # Facts a stamp does not hold leave a bound unknown (`StampFacts`), and an
  # unknown is never drift. A rule with a hand-written guard has none: that
  # guard replaces the extracted one. Stamps with the same rule, decision
  # and facts collapse into one drift, listing where each was seen.
  Drift = Struct.new(:rule, :resource, :decision, :bound, :facts, :location, :seen, :raised, keyword_init: true) do
    def allow? = decision == "allow"

    # The drift in each unit's stamps, in unit order.
    def self.find(mapping, units)
      units.flat_map { |unit| of(mapping, unit) }
    end

    def self.of(mapping, unit)
      extracted = unit.extracted
      return [] unless extracted && extracted.resource == unit.resource && !mapping.rules[unit.key]&.guard

      groups = contradicted(mapping, unit, extracted).group_by { |stamp, *rest| [stamp.decision, *rest] }
      groups.map do |(decision, bound, facts), group|
        new(rule: unit.key, resource: unit.resource, decision: decision, bound: bound, facts: facts,
            location: extracted.location, **sightings(group.map(&:first)))
      end
    end

    # Each stamp the bound for its decision contradicts, with that bound and
    # the stamp's facts: an allow a false upper bound, a deny a true lower one.
    def self.contradicted(mapping, unit, extracted)
      resource = mapping.fetch(unit.resource)
      unit.stamps.filter_map do |stamp|
        facts = StampFacts.new(mapping, resource, stamp)
        bound = stamp.allow? ? extracted.upper : extracted.lower
        [stamp, bound, facts.to_s] if bound.evaluate(facts) == !stamp.allow?
      end
    end

    def self.sightings(stamps)
      { seen: stamps.map { |stamp| stamp.entry_point || "outside a request" }.uniq.sort,
        raised: stamps.filter_map(&:raised).uniq.sort }
    end
  end
end
