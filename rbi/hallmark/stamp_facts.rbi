# typed: strict

module Hallmark
  class StampFacts
    include Guard::DSL

    sig { returns(Stamp) }
    attr_reader :stamp

    sig { returns(Mapping::Resource) }
    attr_reader :resource

    sig { params(mapping: Mapping, resource: Mapping::Resource, stamp: Stamp).void }
    def initialize(mapping, resource, stamp)
      @mapping = T.let(T.unsafe(nil), Mapping)
      @resource = T.let(T.unsafe(nil), Mapping::Resource)
      @stamp = T.let(T.unsafe(nil), Stamp)
    end

    sig { returns(T::Array[Guard]) }
    def literals; end

    # nil is unknown
    sig { params(leaf: Guard).returns(T.nilable(T::Boolean)) }
    def [](leaf); end

    sig { returns(String) }
    def to_s; end

    private

    sig { returns(T::Array[Guard]) }
    def record_literals; end

    sig { returns(T::Array[Guard]) }
    def record_tenant_literals; end

    sig { returns(T::Array[String]) }
    def outside_roles; end

    sig { returns(T::Array[String]) }
    def record_roles; end

    sig { returns(T::Array[String]) }
    def current_roles; end

    sig { params(value: T.nilable(T::Array[String])).returns(T::Array[String]) }
    def names(value); end

    sig { params(value: T.nilable(T::Boolean)).returns(T.nilable(T::Boolean)) }
    def fact(value); end

    sig { returns(T.nilable(T::Boolean)) }
    def public_fact; end

    sig { returns(T.nilable(T::Boolean)) }
    def outside_tenants_fact; end

    sig { returns(T.nilable(T::Boolean)) }
    def in_current_tenant_fact; end

    sig { params(name: String, tenant: T.nilable(Symbol)).returns(T.nilable(T::Boolean)) }
    def role_fact(name, tenant); end

    sig { params(name: String).returns(T.nilable(T::Boolean)) }
    def current_role_fact(name); end

    sig { returns(T.nilable(T::Boolean)) }
    def member_fact; end

    sig { params(name: String).returns(T.nilable(T::Boolean)) }
    def record_role_fact(name); end

    sig { returns(T::Array[String]) }
    def record_labels; end

    sig { returns(T::Array[String]) }
    def tenant_labels; end

    sig { params(name: String, value: T.nilable(T::Boolean)).returns(String) }
    def label(name, value); end
  end
end
