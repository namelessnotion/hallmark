# typed: strict

module Hallmark
  class Exposure
    sig { returns(String) }
    def action; end

    sig { returns(Symbol) }
    def op; end

    sig { returns(String) }
    def resource; end

    sig { returns(Guard) }
    def guard; end

    # Where an inferred guard came from; nil for a hand-declared exposure
    sig { returns(T.nilable(String)) }
    def basis; end

    # "file:line" strings, the entry point's first; nil or empty when declared by hand
    sig { returns(T.nilable(T::Array[String])) }
    def locations; end

    # The rules whose guards it combines ("LinkPolicy#update?"); nil when declared by hand
    sig { returns(T.nilable(T::Array[String])) }
    def rules; end

    sig do
      params(action: String, op: Symbol, resource: String, guard: Guard, basis: T.nilable(String),
             locations: T.nilable(T::Array[String]), rules: T.nilable(T::Array[String])).void
    end
    def initialize(action:, op:, resource:, guard:, basis: nil, locations: nil, rules: nil); end

    sig { returns(String) }
    def check_name; end

    sig { returns(String) }
    def predicate_name; end

    # "<action>_<op>_<resource>" as Alloy identifiers, shared by both names
    sig { returns(String) }
    def name_suffix; end

    sig { returns(String) }
    def to_s; end

    # SHA-256 hex of the check as the model builder renders it
    sig { params(mapping: Mapping).returns(String) }
    def digest(mapping); end
  end
end
