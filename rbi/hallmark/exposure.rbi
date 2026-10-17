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

    sig { params(action: String, op: Symbol, resource: String, guard: Guard, basis: T.nilable(String)).void }
    def initialize(action:, op:, resource:, guard:, basis: nil); end

    sig { returns(String) }
    def check_name; end

    sig { returns(String) }
    def predicate_name; end

    # "<action>_<op>_<resource>" as Alloy identifiers, shared by both names
    sig { returns(String) }
    def name_suffix; end

    sig { returns(String) }
    def to_s; end
  end
end
