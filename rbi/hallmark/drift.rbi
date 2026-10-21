# typed: strict

module Hallmark
  class Drift
    # "LinkPolicy#show?"
    sig { returns(String) }
    def rule; end

    sig { returns(String) }
    def resource; end

    # "allow" or "deny"
    sig { returns(String) }
    def decision; end

    # The extracted guard's upper bound for an allow, lower bound for a deny
    sig { returns(Guard) }
    def bound; end

    # The stamp's facts, as `StampFacts#to_s` prints them
    sig { returns(String) }
    def facts; end

    # The rule's file:line (`Extractor::Extracted#location`)
    sig { returns(String) }
    def location; end

    # Entry points the stamps came from, sorted; "outside a request" for none
    sig { returns(T::Array[String]) }
    def seen; end

    # Exception classes raised inside the rule, sorted
    sig { returns(T::Array[String]) }
    def raised; end

    sig do
      params(rule: String, resource: String, decision: String, bound: Guard, facts: String, location: String,
             seen: T::Array[String], raised: T::Array[String]).void
    end
    def initialize(rule:, resource:, decision:, bound:, facts:, location:, seen:, raised:); end

    sig { returns(T::Boolean) }
    def allow?; end

    # "<rule>|<decision>|<facts>"
    sig { returns(String) }
    def key; end

    sig { params(mapping: Mapping, units: T::Array[Inference::Unit]).returns(T::Array[Drift]) }
    def self.find(mapping, units); end

    sig { params(mapping: Mapping, unit: Inference::Unit).returns(T::Array[Drift]) }
    def self.of(mapping, unit); end

    sig do
      params(mapping: Mapping, unit: Inference::Unit, extracted: Extractor::Extracted)
        .returns(T::Array[[Stamp, Guard, String]])
    end
    def self.contradicted(mapping, unit, extracted); end

    sig { params(stamps: T::Array[Stamp]).returns({ seen: T::Array[String], raised: T::Array[String] }) }
    def self.sightings(stamps); end
  end
end
