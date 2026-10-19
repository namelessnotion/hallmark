# typed: strict

module Hallmark
  class Guard
    sig { returns(Symbol) }
    attr_reader :kind

    # Guards for :and, :or and :not; a role name (String) and where it is
    # held (nil or a Symbol from ROLE_TENANTS) for :role.
    sig { returns(T::Array[T.untyped]) }
    attr_reader :operands

    sig { params(kind: Symbol, operands: T.untyped).void }
    def initialize(kind, *operands)
      @kind = T.let(T.unsafe(nil), Symbol)
      @operands = T.let(T.unsafe(nil), T::Array[T.untyped])
    end

    sig { params(other: Guard).returns(Guard) }
    def &(other); end

    sig { params(other: Guard).returns(Guard) }
    def |(other); end

    sig { returns(Guard) }
    def ~; end

    sig { params(op: T.nilable(String)).returns(String) }
    def to_alloy(op = nil); end

    sig { returns(T::Array[Guard]) }
    def leaves; end

    sig { returns(T::Array[String]) }
    def roles; end

    sig { returns(T::Array[Symbol]) }
    def tenants; end

    sig { returns(T::Boolean) }
    def permits?; end

    sig { returns(T::Array[String]) }
    def flags; end

    sig { returns(T::Boolean) }
    def outside_tenants?; end

    sig { returns(T::Array[String]) }
    def roles_outside_tenants; end

    sig { returns(String) }
    def to_s; end

    sig { returns(String) }
    def inspect; end

    # `eql?` is an alias, so it shares this signature.
    sig { params(other: Object).returns(T::Boolean) }
    def ==(other); end

    sig { returns(Integer) }
    def hash; end

    sig { returns(T::Boolean) }
    def opaque?; end

    sig { returns(T::Array[Guard]) }
    def opaque_leaves; end

    # [lower, upper]
    sig { returns([Guard, Guard]) }
    def bounds; end

    sig { returns(Guard) }
    def lower; end

    sig { returns(Guard) }
    def upper; end

    # nil is unknown
    sig { params(facts: T.any(StampFacts, T::Hash[Guard, T::Boolean])).returns(T.nilable(T::Boolean)) }
    def evaluate(facts); end

    sig { params(left: Guard, right: Guard).returns(Guard) }
    def self.conjoin(left, right); end

    sig { params(left: Guard, right: Guard).returns(Guard) }
    def self.disjoin(left, right); end

    sig { params(guard: Guard).returns(Guard) }
    def self.negate(guard); end

    protected

    sig { params(lower: T::Boolean).returns(Guard) }
    def bound(lower); end

    private

    sig { params(left: T.nilable(T::Boolean), right: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def both(left, right); end

    sig { params(left: T.nilable(T::Boolean), right: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def either(left, right); end

    sig { params(tenant: T.nilable(Symbol)).returns(String) }
    def role_set(tenant); end

    # Checked at run time, since callers without Sorbet can pass anything.
    sig { params(other: Object).returns(Guard) }
    def coerce(other); end

    module DSL
      sig { returns(Guard) }
      def none; end

      sig { returns(Guard) }
      def logged_in; end

      sig { returns(Guard) }
      def owner; end

      sig { returns(Guard) }
      def admin; end

      sig { returns(Guard) }
      def public_record; end

      sig { params(name: T.any(String, Symbol), tenant: T.nilable(Symbol)).returns(Guard) }
      def role(name, tenant: nil); end

      sig { returns(Guard) }
      def in_current_tenant; end

      sig { returns(Guard) }
      def outside_tenants; end

      sig { returns(Guard) }
      def permitted; end

      sig { params(name: T.any(String, Symbol)).returns(Guard) }
      def flag(name); end
    end
  end
end
