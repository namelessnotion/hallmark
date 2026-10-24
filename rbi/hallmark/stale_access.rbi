# typed: strict

module Hallmark
  class StaleAccess
    # "LinkPolicy#update?"
    sig { returns(String) }
    def rule; end

    sig { returns(String) }
    def resource; end

    # The role names lost, sorted
    sig { returns(T::Array[String]) }
    def revoked; end

    # The stamp's facts, as `StampFacts#to_s` prints them
    sig { returns(String) }
    def facts; end

    # "the current tenant", "the record's tenant" or either
    sig { returns(String) }
    def tenant; end

    # The rule's file:line, when read from code
    sig { returns(T.nilable(String)) }
    def location; end

    # Entry points the stamps came from, sorted; "outside a request" for none
    sig { returns(T::Array[String]) }
    def seen; end

    sig do
      params(rule: String, resource: String, revoked: T::Array[String], facts: String, tenant: String,
             location: T.nilable(String), seen: T::Array[String]).void
    end
    def initialize(rule:, resource:, revoked:, facts:, tenant:, location:, seen:); end

    # "<rule>|<resource>|<revoked>|<facts>"
    sig { returns(String) }
    def key; end

    sig do
      params(mapping: Mapping, stamps: T::Array[Stamp], units: T::Array[Inference::Unit], coverage: Coverage)
        .returns(T::Array[StaleAccess])
    end
    def self.judge(mapping, stamps, units, coverage); end

    sig do
      params(rule: String, resource: String, revoked: T::Array[String], facts: String,
             group: T::Array[[Stamp, Inference::Unit]]).returns(StaleAccess)
    end
    def self.build(rule, resource, revoked, facts, group); end

    sig { params(stamp: Stamp, units: T::Array[Inference::Unit]).returns(T.nilable(Inference::Unit)) }
    def self.unit_for(stamp, units); end

    sig { params(mapping: Mapping, stamp: Stamp, unit: T.nilable(Inference::Unit)).returns(T.nilable(T::Boolean)) }
    def self.verdict(mapping, stamp, unit); end

    sig { params(coverage: Coverage, stamp: Stamp, verdict: T.nilable(T::Boolean)).void }
    def self.note(coverage, stamp, verdict); end

    sig { params(mapping: Mapping, stamp: Stamp).returns(String) }
    def self.facts_of(mapping, stamp); end

    sig { params(stamp: Stamp, revoked: T::Array[String]).returns(String) }
    def self.tenant_of(stamp, revoked); end
  end
end
