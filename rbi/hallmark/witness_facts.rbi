# typed: strict

module Hallmark
  class WitnessFacts
    sig { params(finding: Finding, platform_roles: T::Array[String]).void }
    def initialize(finding, platform_roles)
      @finding = T.let(T.unsafe(nil), Finding)
      @platform_roles = T.let(T.unsafe(nil), T::Array[String])
    end

    # nil is unknown
    sig { params(leaf: Guard).returns(T.nilable(T::Boolean)) }
    def [](leaf); end

    sig { params(guard: Guard).returns(T.nilable(T::Boolean)) }
    def evaluate(guard); end

    sig { params(denial: Restriction::Denial).returns(T::Boolean) }
    def denied?(denial); end

    private

    sig { params(name: String, tenant: T.nilable(Symbol)).returns(T.nilable(T::Boolean)) }
    def role_held?(name, tenant); end

    sig { returns(T.nilable(T::Boolean)) }
    def in_current_tenant; end
  end
end
